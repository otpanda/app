import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../browser_session_contract.dart';
import '../entry_domains.dart';
import '../google_link.dart';
import '../recovery_contract.dart';
import '../session_contract.dart';
import 'native_assignment.dart';
import 'native_device_routes.dart';
import 'native_email_recovery.dart';
import 'native_google_link.dart';
import 'native_manage_settings.dart';
import 'native_passkey.dart';
import 'native_realtime.dart';
import 'native_session.dart';

/// Trims and caps a device label at 40 code points (never splits a surrogate
/// pair). Null when empty.
String? cappedDeviceLabel(String? raw) {
  final v = raw?.trim();
  if (v == null || v.isEmpty) return null;
  final runes = v.runes;
  return runes.length > 40 ? String.fromCharCodes(runes.take(40)) : v;
}

/// One bearer-authenticated API request (no cookies, no Origin). The real
/// implementation lives in android_adapters.dart (dart:io).
typedef BearerRequest = Future<SessionResponse> Function(
  String method,
  String path, {
  String? body,
  Map<String, String>? query,
  required String bearer,
});

/// Same as [BearerRequest] plus extra request headers (only the one-time
/// X-OTPanda-Enrollment header is ever sent through it).
typedef HeaderRequest = Future<SessionResponse> Function(
  String method,
  String path, {
  String? body,
  required String bearer,
  required Map<String, String> headers,
});

/// The shared account UI talks to this exactly as it talks to the web bridge.
/// Same allow-listed paths and bodies as tool/session-bootstrap.js; the only
/// difference is where the bearer comes from (NativeSessionController).
/// Read-only plus organization and copy receipts and code reads. Passkey,
/// TOTP creation, Google link and recovery steps need step-up and have no
/// native-safe API route yet. They are unsupported now (not a permanent
/// policy) and the shared UI hides them via TotpCreationUnavailable.
class NativeSessionBridge
    implements
        BrowserSessionBridge,
        SessionContinuityBridge,
        TotpManagementBridge,
        TotpBatchBridge,
        TotpCreationCapability,
        AssignmentBridge,
        EntryManagementBridge,
        EntryDomainsBridge,
        AuthEntryBridge,
        FirstPasskeyBridge,
        AdditionalPasskeyBridge,
        RecoveryBridge,
        PasskeyLabelBridge,
        GoogleConnectBridge,
        GoogleLinkBridge,
        RealtimeBridge {
  /// Set once after construction (the driver needs this bridge's transport).
  NativeAssignmentDriver? assignment;

  NativeSessionBridge(
    this.controller,
    this._request, {
    this.onLogout,
    this.passkeys,
    this.deviceLabel,
    bool googleAvailable = false,
    bool Function()? googleAvailability,
    this.creation,
    this.headerRequest,
    this.settingsEnabled = false,
    RealtimeConnector? realtimeConnector,
    int Function()? now,
  }) : _googleAvailability = googleAvailability ?? (() => googleAvailable),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (realtimeConnector != null) {
      _realtime = NativeRealtimeClient(
        mint: _mintTicket,
        connect: realtimeConnector,
        onRevoked: () async {
          await controller.forceRenew();
        },
      );
      _lastPhase = controller.phase;
      controller.addListener(_onPhase);
    }
  }

  NativeSessionPhase? _lastPhase;
  String? _rejectedAccess;

  /// Session changes drive realtime: signed out tears the socket down (the
  /// listeners stay), and a session coming back reconnects an ended run.
  void _onPhase() {
    final p = controller.phase, before = _lastPhase;
    _lastPhase = p;
    if (p == NativeSessionPhase.signedOut ||
        p == NativeSessionPhase.signInRequired) {
      if (p != before) _realtime?.sessionEnded();
    } else if (p == NativeSessionPhase.signedIn) {
      // Only a session the server has not already rejected can restart an
      // ended run: a fresh sign-in, or a renewal that issued a new token.
      final a = controller.session?.access;
      if (a != null && a != _rejectedAccess) _realtime?.sessionRestored();
    }
  }

  /// App foreground state for realtime (resumed = true). Safe to call
  /// repeatedly; without a connector it does nothing.
  void realtimeSetForeground(bool foreground) =>
      _realtime?.setForeground(foreground);

  /// Stops listening to the session. Call when the bridge is discarded.
  void disposeRealtime() {
    if (_realtime == null) return;
    controller.removeListener(_onPhase);
    _realtime!.sessionEnded();
  }

  /// A ticket request, or a TicketPause when no request could be made. The
  /// bridge's own pause answer is never mistaken for a server 503: a signed
  /// out or rejected session ends realtime, a restoring or offline one waits.
  Future<SessionResponse> _mintTicket() async {
    // The server already rejected this exact token twice: no request, wait for
    // a renewal or sign-in that yields a different one.
    if (_rejectedAccess != null &&
        controller.session?.access == _rejectedAccess) {
      throw const TicketPause(ended: true);
    }
    final r = await _call('POST', '/auth/realtime/ticket');
    final p = controller.phase;
    final over =
        p == NativeSessionPhase.signedOut ||
        p == NativeSessionPhase.signInRequired;
    if (r.status == 401 && over) throw const TicketPause(ended: true);
    if (!identical(r, _paused)) return r;
    if (p == NativeSessionPhase.signedIn) {
      _rejectedAccess = controller.session?.access;
    }
    throw TicketPause(ended: over || p == NativeSessionPhase.signedIn);
  }

  static const _paused = SessionResponse(503, '{}');

  NativeRealtimeClient? _realtime;

  /// Foreground-only realtime hints. No connector (tests, other builds) means
  /// no realtime, and the listener is never called.
  @override
  void Function() realtimeSubscribe(void Function(String reason) listener) =>
      _realtime?.subscribe(listener) ?? () {};

  final PasskeyAssertionSource? passkeys;
  final int Function() _now;

  /// Best-effort display label (user-set device name, else model), or null.
  final Future<String?> Function()? deviceLabel;
  String? _describedKey;
  String? _blockedKey;
  int _retryAt = 0;
  bool _describing = false;
  static const _describeBackoffMs = 60000;

  @override
  bool get canAddTotp => passkeys?.available ?? false;

  final NativeSessionController controller;
  final BearerRequest _request;
  final HeaderRequest? headerRequest;

  /// OS passkey creation (Credential Manager). Null: not offered.
  final PasskeyCreationSource? creation;
  final void Function()? onLogout;

  static const _reads = {
    '/v1/manage/account',
    '/v1/manage/session',
    '/v1/manage/entries',
    '/v1/manage/active-codes',
    '/v1/manage/sources',
    '/v1/manage/unassigned',
  };

  @override
  Future<void> get ready async {}

  @override
  String get status =>
      controller.phase == NativeSessionPhase.signedIn ||
          controller.phase == NativeSessionPhase.offline ||
          controller.phase == NativeSessionPhase.unknown
      ? _sessionStatus
      : (controller.auth.signupStage ??
            controller.auth.googleLinkStage ??
            _sessionStatus);

  String get _sessionStatus => switch (controller.phase) {
    NativeSessionPhase.signedIn => 'restored',
    NativeSessionPhase.offline => 'session-paused',
    NativeSessionPhase.unknown => 'restoring',
    _ => 'sign-in-required',
  };

  @override
  int get accessExpiresAt => controller.session?.accessExpiresAt ?? 0;

  @override
  Future<void> maintain() async {
    final token = await controller.accessToken();
    if (token == null) {
      if (controller.phase != NativeSessionPhase.offline) _resetDescribe();
      return;
    }
    _kickDescribe();
  }

  void _resetDescribe() {
    _describedKey = null;
    _blockedKey = null;
    _retryAt = 0;
  }

  /// Never awaited by maintain(): a stalled label source or request cannot hold
  /// up token upkeep. One attempt at a time, bounded by a deadline.
  void _kickDescribe() {
    if (deviceLabel == null || _describing || _now() < _retryAt) return;
    _describing = true;
    unawaited(
      _describe()
          .timeout(const Duration(seconds: 10))
          .catchError((Object _) {
            _retryAt = _now() + _describeBackoffMs;
          })
          .whenComplete(() => _describing = false),
    );
  }

  /// Tells the server what to call this session (display only). Keyed by the
  /// session (device id) plus label: sent once per session, again when either
  /// changes. 400/403/405 mean the server will not take it (flag off, wrong
  /// route): stop for this key. Other failures back off. Never affects the session.
  Future<void> _describe() async {
    final get = deviceLabel!;
    final id = controller.session?.deviceId;
    if (id == null) return;
    final name = cappedDeviceLabel(await get());
    final key = '$id|${name ?? ''}';
    if (_describedKey == key || _blockedKey == key) return;
    final r = await _call(
      'POST',
      '/v1/manage/session/describe',
      body: jsonEncode({'browser': null, 'os': 'android', 'name': name}),
    );
    if (r.status == 200) {
      _describedKey = key;
    } else if (r.status == 400 || r.status == 403 || r.status == 405) {
      _blockedKey = key;
    } else {
      _retryAt = _now() + _describeBackoffMs;
    }
  }

  /// True on the Google flavor with Play Services (OS Google sign-in).
  final bool Function() _googleAvailability;
  bool get googleAvailable => _googleAvailability();

  // Shared sign-in screen (AuthEntry). Same screen as web; only the platform
  // action differs. Failures land in controller.lastError.
  @override
  String get email => controller.auth.googleLinkEmail;
  @override
  String get pendingLabel => '';

  // ---- Recovery, security settings, passkey rename, Google link. Contract:
  // native-settings-parity-CONTRACT-ef156abe. OFF unless [settingsEnabled]
  // (activation is primary's, after deployment and qualification). Approval
  // of new-device sign-ins is never offered: it answers 503
  // local_verification_unavailable. Deny works.
  final bool settingsEnabled;

  late final NativeManageSettings? _manage = settingsEnabled && passkeys != null
      ? NativeManageSettings(
          passkeys: passkeys!,
          nowMs: _now,
          request: (m, p, b) async {
            final r = await _call(m, p, body: b == null ? null : jsonEncode(b));
            Map<String, dynamic>? body;
            try {
              final j = jsonDecode(r.body);
              if (j is Map<String, dynamic>) body = j;
            } catch (_) {}
            return (status: r.status, body: body);
          },
        )
      : null;

  late final NativeEmailRecovery? _email = settingsEnabled && creation != null
      ? NativeEmailRecovery(
          post: controller.auth.post,
          creation: creation!,
          nowMs: _now,
        )
      : null;

  NativeManageSettings get _m =>
      _manage ?? (throw UnsupportedError('Not available on this device.'));
  NativeEmailRecovery get _e =>
      _email ?? (throw UnsupportedError('Not available on this device.'));

  @override
  bool get recoveryAvailable => _manage != null;

  late final NativeGoogleConnect? _connect = _manage == null
      ? null
      : NativeGoogleConnect(
          settings: _manage,
          browser: controller.auth.browser,
          apiOrigin: controller.auth.apiOrigin,
          nowMs: _now,
        );

  @override
  bool get googleConnectAvailable => _connect != null;
  @override
  Future<String> connectGoogle() async => _connect?.connect() ?? 'unavailable';
  @override
  String takeGoogleLinkResult() => _connect?.takeResult() ?? '';

  /// Disconnect uses the same recovery step-up as web: kind google-unlink, no
  /// target, one fresh passkey assertion bound to that change. Only with the
  /// settings switch (same as every other settings action). A success can
  /// invalidate Google-authenticated sessions, including this one: the next
  /// call then gets a 401, the renew is refused (invalid_grant) and the
  /// controller goes to signInRequired with the key kept.
  @override
  bool get googleDisconnectAvailable => recoveryAvailable;
  @override
  Future<void> disconnectGoogle() async =>
      _m.recoveryChange(const RecoveryChange(RecoveryKind.googleUnlink));

  /// Local-verification approval is not available on any client.
  @override
  bool get enrolledClientApprovalAvailable => false;

  @override
  Future<RecoveryStatus> recoveryStatus() async =>
      RecoveryStatus.fromJson(await _m.recoveryStatus());

  @override
  Future<void> recoveryChange(RecoveryChange change) async =>
      _m.recoveryChange(change);

  @override
  Future<void> recoveryCancelRequest(String requestId) async =>
      _m.cancelRequest(requestId);

  @override
  Future<void> renamePasskey(String credentialId, String? label) async =>
      _m.renamePasskey(credentialId, label);

  @override
  Future<void> emailRecoveryStart(String email) async => _e.start(email);
  @override
  Future<DateTime> emailRecoveryVerify(String email, String code) async =>
      _e.verify(email, code);
  @override
  Future<void> emailRecoverySendCompletionCode(String email) async =>
      _e.sendCompletionCode(email);
  @override
  Future<void> emailRecoveryComplete(String email, String code) async =>
      _e.complete(email, code);

  /// Google: the OS account sheet when the SDK is there, otherwise the
  /// browser handoff (also what controller does on browser_required).
  @override
  Future<void> googleStart(bool remember) => googleAvailable
      ? controller.signInWithGoogle(remember: true)
      : controller.signInWithBrowser(provider: 'google', remember: true);

  /// INTERIM for account creation: no native register route exists, so it
  /// uses the browser handoff.
  /// Native signup: no proof sends the code; with a code it verifies it and
  /// prepares the passkey ceremony (status then becomes 'signup-ready').
  @override
  Future<void> signupEmail(String email, [String proof = '']) async {
    final a = email.trim();
    if (proof.isEmpty) return controller.signupEmail(a);
    return controller.signupBegin(a, proof.replaceAll(RegExp(r'[\s-]'), ''));
  }

  /// Only kind "link" exists natively: an OS passkey step-up by the owner of
  /// the existing account. No email step.
  @override
  Future<void> googleContinue(String action, [String proof = '']) async {
    if (action == 'link-cancel') return controller.googleLinkAbort();
    final p = passkeys;
    if (action != 'link' ||
        p == null ||
        controller.auth.googleLinkStage == null) {
      throw StateError('Start Google sign-in again.');
    }
    await controller.googleLinkFinish(p);
  }

  @override
  Future<String> protectionContinue(String action) =>
      throw UnsupportedError('Not available on this device.');

  /// Same actions as the web bridge. approve and approve-change are never
  /// available (503 on every client); deny is.
  @override
  Future<String> security(
    String action, [
    bool enabled = false,
    String pendingId = '',
  ]) async {
    final m = _m;
    switch (action) {
      case 'status':
        return jsonEncode(await m.securityStatus());
      case 'toggle':
        await m.setExtraVerification(enabled);
        return '{}';
      case 'request-change':
        return jsonEncode(await m.requestSecurityChange(enabled));
      case 'consume-change':
        return jsonEncode(await m.consumeSecurityChange(pendingId));
      case 'deny':
        await m.denyPending(pendingId);
        return '{}';
      default:
        throw UnsupportedError('Not available on this device.');
    }
  }

  @override
  Future<void> start(String mode) async {
    if (mode == 'google') return googleStart(true);
    if (mode == 'login') {
      // OS passkey when Credential Manager is available (google flavor);
      // otherwise the browser handoff (fdroid has no native passkey).
      return (passkeys?.available ?? false)
          ? controller.signInWithPasskey()
          : controller.signInWithBrowser();
    }
  }

  /// 'signup-ready': create the passkey through the OS and finish signup.
  @override
  Future<void> passkey() async {
    final c = creation;
    if (controller.auth.signupStage != 'signup-ready' || c == null) {
      throw StateError('Start sign-up again.');
    }
    await controller.signupFinish(c);
  }

  /// "Other ways to continue": drops any signup in progress and its pending key.
  @override
  void clear() {
    unawaited(controller.signupAbort());
    unawaited(controller.googleLinkAbort());
  }

  @override
  void logout() {
    assignment?.clear();
    _resetDescribe();
    onLogout?.call();
  }

  /// One attempt, and on 401 one renewal then one retry. A second 401 or a
  /// renewal that cannot finish is reported as 503 (session paused) like the
  /// web bridge, never as proof the account is signed out.
  Future<SessionResponse> _call(
    String method,
    String path, {
    String? body,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await controller.accessToken();
      if (token == null) {
        return controller.phase == NativeSessionPhase.offline
            ? _paused
            : const SessionResponse(401, '{}');
      }
      final h = headers;
      final r = h == null
          ? await _request(
              method,
              path,
              body: body,
              query: query,
              bearer: token,
            )
          : await (headerRequest ??
                (m, p, {body, required bearer, required headers}) async =>
                    throw StateError('Not available on this device.'))(
              method,
              path,
              body: body,
              bearer: token,
              headers: h,
            );
      if (r.status != 401) return r;
      await controller.forceRenew();
    }
    return _paused;
  }

  /// Owned-entry edits. Exact keys, label trimmed to 1..120, account null
  /// clears it. One request, never repeated by this code: a 401 is renewed and
  /// retried by [_call] only because the server rejected it before any write.
  /// Anything but a typed 200 {ok:true} is "not confirmed".
  Future<void> _entryEdit(String kind, Map<String, dynamic> body) async {
    final r = await _call(
      'POST',
      '/v1/manage/entry/$kind',
      body: jsonEncode(body),
    );
    var ok = false;
    try {
      final v = r.body.length <= 1024 ? jsonDecode(r.body) : null;
      ok = r.status == 200 && v is Map && v['ok'] == true;
    } on FormatException {
      ok = false;
    }
    if (!ok) throw StateError('Not confirmed');
  }

  static final _entryId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  @override
  Future<Map<String, List<String>>> readEntryDomains() async {
    final r = await _call('GET', '/v1/manage/entry/domains');
    if (r.status != 200) throw StateError('Not available');
    try {
      return parseEntryDomains(r.body);
    } on FormatException {
      throw StateError('Not available');
    }
  }

  @override
  Future<List<String>> replaceEntryDomains(
    String entryId,
    List<String> domains,
  ) async {
    final body = entryDomainsBody(entryId, domains);
    if (body == null) throw StateError('Website change required');
    final sent = (body['domains'] as List).cast<String>();
    // One request. The 401 renew-and-retry in _call only happens before the
    // server has accepted anything.
    final r = await _call(
      'POST',
      '/v1/manage/entry/domains',
      body: jsonEncode(body),
    );
    if (!entryDomainsConfirmed(r.status, r.body, sent)) {
      throw StateError('Not confirmed');
    }
    return sent;
  }

  @override
  Future<void> renameEntry(String entryId, String label) async {
    final v = label.trim();
    if (!_entryId.hasMatch(entryId) || v.isEmpty || v.length > 120) {
      throw StateError('Entry change required');
    }
    await _entryEdit('rename', {'entryId': entryId, 'label': v});
  }

  @override
  Future<void> updateAccount(String entryId, String? account) async {
    final v = account?.trim();
    if (!_entryId.hasMatch(entryId) ||
        (account != null && (v!.isEmpty || v.length > 120))) {
      throw StateError('Entry change required');
    }
    await _entryEdit('account', {'entryId': entryId, 'accountName': v});
  }

  /// Assignment POSTs: only the three assignment paths with their exact key
  /// sets, no query, bearer from the session. Small JSON object answers only.
  Future<({int status, Map<String, dynamic>? body})> assignmentPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!assignmentRequestAllowed(path, body)) {
      throw StateError('Assignment request required');
    }
    final r = await _call('POST', path, body: jsonEncode(body));
    Map<String, dynamic>? parsed;
    try {
      final v = r.body.length <= 16384 ? jsonDecode(r.body) : null;
      if (v is Map<String, dynamic>) parsed = v;
    } on FormatException {
      parsed = null;
    }
    return (status: r.status, body: parsed);
  }

  NativeAssignmentDriver get _assignment {
    final a = assignment;
    if (a == null) throw StateError('Assignment unavailable');
    return a;
  }

  @override
  Future<String> assignmentPrepare(String target) =>
      _assignment.prepare(target);
  @override
  Future<String> assignmentConfirm() => _assignment.confirm();
  @override
  Future<String> assignmentReconcile() => _assignment.reconcile();
  @override
  String get assignmentState => assignment?.state ?? 'idle';
  @override
  void assignmentDismiss() => assignment?.dismiss();

  /// Device-key enrollment POSTs: only the five v8 paths with their exact key
  /// sets, no query, bearer from the session. Responses are small JSON objects
  /// (anything else becomes a null body). Unused until the flow is wired.
  Future<({int status, Map<String, dynamic>? body})> deviceKeyPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (!deviceKeyRequestAllowed(path, body)) {
      throw StateError('Device-key request required');
    }
    final r = await _call('POST', path, body: jsonEncode(body));
    Map<String, dynamic>? parsed;
    try {
      final v = r.body.length <= 16384 ? jsonDecode(r.body) : null;
      if (v is Map<String, dynamic>) parsed = v;
    } on FormatException {
      parsed = null;
    }
    return (status: r.status, body: parsed);
  }

  @override
  Future<SessionResponse> read(String path) {
    if (!_reads.contains(path)) throw StateError('Read path required');
    return _call('GET', path);
  }

  @override
  Future<SessionResponse> organize(String method, String body) {
    if (!{'GET', 'PUT'}.contains(method) ||
        utf8.encode(body).length > 131072 ||
        (method == 'GET' && body.isNotEmpty)) {
      throw StateError('Organization request required');
    }
    return _call(
      method,
      '/v1/manage/organization',
      body: method == 'PUT' ? body : null,
    );
  }

  @override
  Future<SessionResponse> copied(String entryId, int createdAt) {
    if (entryId.isEmpty || entryId.length > 256) {
      throw StateError('Copy receipt required');
    }
    final r = Random.secure();
    final receipt = base64Url
        .encode(List.generate(18, (_) => r.nextInt(256)))
        .replaceAll('=', '');
    return _call(
      'POST',
      '/v1/manage/organization-copy',
      body: jsonEncode({
        'entryId': entryId,
        'receiptId': receipt,
        'createdAt': createdAt,
      }),
    );
  }

  @override
  Future<SessionResponse> totpBatch(
    List<String> entryIds, {
    required int windowSeconds,
  }) {
    if (entryIds.isEmpty ||
        entryIds.length > 49 ||
        entryIds.toSet().length != entryIds.length ||
        entryIds.any(
          (e) =>
              e.isEmpty ||
              e.length > 64 ||
              RegExp(r'[\x00-\x20\x7f]').hasMatch(e),
        ) ||
        windowSeconds < 1 ||
        windowSeconds > 600) {
      throw ArgumentError('Invalid batch request');
    }
    final query = Uri(
      queryParameters: {'entry': entryIds, 'window': '$windowSeconds'},
    ).query;
    return _call('GET', '/v1/manage/totp-codes?$query');
  }

  @override
  Future<SessionResponse> totpCode(String entryId) =>
      _call('GET', '/v1/manage/totp-code', query: {'entry': entryId});

  // ---- Passkey creation (same URLs and bodies as tool/session-bootstrap.js).
  // Nothing here is a completed enrollment until the server answers 200.

  bool _finishSent = false;

  bool get _canCreate => creation?.available ?? false;

  /// The one-time Google enrollment grant, only while it is fresh.
  String? get _freshGrant {
    final s = controller.session;
    final at = s?.grantAtMs;
    if (s?.enrollGrant == null || at == null) return null;
    return _now() - at < 110000 ? s!.enrollGrant : null;
  }

  @override
  bool get firstPasskeyAvailable => _canCreate && _freshGrant != null;

  Future<Map<String, dynamic>> _json(SessionResponse r) async {
    if (r.status != 200) throw ClientFailure(r.status);
    final b = jsonDecode(r.body);
    if (b is! Map<String, dynamic>) throw StateError('Invalid response');
    return b;
  }

  Future<void> _createAndFinish({
    required Map<String, dynamic> begin,
    required bool first,
    required String finishPath,
    required Map<String, String> headers,
  }) async {
    final source = creation!;
    final request = passkeyCreationRequestJson(
      begin,
      nowMs: _now(),
      first: first,
    );
    final raw = await source.create(request);
    if (raw == null) throw StateError('Passkey setup cancelled');
    _finishSent = true;
    final done = await _call(
      'POST',
      finishPath,
      body: jsonEncode({
        'token': begin['token'],
        'response': passkeyRegistrationBody(raw),
      }),
      headers: headers,
    );
    if (done.status != 200) throw ClientFailure(done.status);
    final d = jsonDecode(done.body);
    if (d is! Map || d['status'] != 'registered') {
      throw StateError('Passkey setup was not confirmed.');
    }
  }

  @override
  Future<void> firstPasskey() async {
    final grant = _freshGrant;
    if (!_canCreate || grant == null) {
      throw StateError('Sign in with Google again to add your first passkey.');
    }
    final h = {'X-OTPanda-Enrollment': grant};
    final begin = await _json(
      await _call(
        'POST',
        '/v1/manage/first-passkey/begin',
        body: '{}',
        headers: h,
      ),
    );
    try {
      await _createAndFinish(
        begin: begin,
        first: true,
        finishPath: '/v1/manage/first-passkey/finish',
        headers: h,
      );
    } finally {
      // The one-time grant is spent once finish was sent (the server consumes
      // it on finish). A cancel before finish keeps it.
      if (_finishSent) controller.consumeEnrollGrant();
      _finishSent = false;
    }
  }

  @override
  Future<void> addPasskey() async {
    final get = passkeys;
    if (!_canCreate || get == null || !get.available) {
      throw StateError('Passkeys are not available on this device.');
    }
    final v = await _json(
      await _call('POST', '/v1/manage/passkey/add/verify-begin', body: '{}'),
    );
    final request = passkeyRequestJson(v, nowMs: _now());
    final assertion = await get.get(request);
    if (assertion == null) throw StateError('Passkey verification cancelled');
    final g = await _json(
      await _call(
        'POST',
        '/v1/manage/passkey/add/verify-finish',
        body: jsonEncode({
          'token': v['token'],
          'response': passkeyAssertionBody(assertion),
        }),
      ),
    );
    final gt = g['token'], exp = g['expiresAt'];
    final now = _now();
    if (gt is! String ||
        !RegExp(r'^otpda_[A-Za-z0-9_-]{55}$').hasMatch(gt) ||
        exp is! int ||
        exp <= now ||
        exp > now + 120000) {
      throw StateError('Invalid authorization');
    }
    final h = {'X-OTPanda-Enrollment': gt};
    final begin = await _json(
      await _call(
        'POST',
        '/v1/manage/passkey/add/register-begin',
        body: '{}',
        headers: h,
      ),
    );
    await _createAndFinish(
      begin: begin,
      first: false,
      finishPath: '/v1/manage/passkey/add/register-finish',
      headers: h,
    );
  }

  /// Same ceremony as the web bridge: begin (server validates the details and
  /// binds device, generation and action), a user-verified passkey assertion
  /// from the OS provider, then finish. The renewal key is never used here.
  @override
  Future<String> addTotp(
    String label,
    String account,
    String secret, {
    String? catalogId,
  }) async {
    final source = passkeys;
    if (label.trim().isEmpty ||
        label.length > 120 ||
        account.length > 120 ||
        secret.length > 2048) {
      throw StateError('Invalid authenticator details');
    }
    if (source == null || !source.available) {
      throw StateError('Passkeys are not available on this device.');
    }
    final value = {
      'label': label,
      'account': account,
      'secret': secret,
      'catalogId': ?catalogId,
    };
    final begin = await _call(
      'POST',
      '/v1/manage/totp/begin',
      body: jsonEncode(value),
    );
    if (begin.status != 200) throw ClientFailure(begin.status);
    final b = jsonDecode(begin.body);
    if (b is! Map<String, dynamic>) throw StateError('Invalid response');
    final assertion = await source.get(passkeyRequestJson(b, nowMs: _now()));
    if (assertion == null) throw StateError('Passkey verification cancelled');
    final done = await _call(
      'POST',
      '/v1/manage/totp',
      body: jsonEncode({
        ...value,
        'token': b['token'],
        'response': passkeyAssertionBody(assertion),
      }),
    );
    if (done.status != 201 && done.status != 200) {
      throw ClientFailure(done.status);
    }
    final r = jsonDecode(done.body);
    final id = r is Map ? r['entryId'] : null;
    if (id is! String || id.isEmpty || id.length > 256) {
      throw StateError('Invalid result');
    }
    return id;
  }
}
