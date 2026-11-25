import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../browser_session_contract.dart';
import '../session_contract.dart';
import 'native_assignment.dart';
import 'native_device_routes.dart';
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
        TotpCreationCapability,
        AssignmentBridge,
        EntryManagementBridge,
        RealtimeBridge {
  /// Set once after construction (the driver needs this bridge's transport).
  NativeAssignmentDriver? assignment;

  NativeSessionBridge(
    this.controller,
    this._request, {
    this.onLogout,
    this.passkeys,
    this.deviceLabel,
    RealtimeConnector? realtimeConnector,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
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
  String get status => switch (controller.phase) {
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

  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {
    throw StateError('Passkeys are managed in the browser for now.');
  }

  @override
  void clear() {}

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
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await controller.accessToken();
      if (token == null) {
        return controller.phase == NativeSessionPhase.offline
            ? _paused
            : const SessionResponse(401, '{}');
      }
      final r = await _request(
        method,
        path,
        body: body,
        query: query,
        bearer: token,
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
  Future<SessionResponse> totpCode(String entryId) =>
      _call('GET', '/v1/manage/totp-code', query: {'entry': entryId});

  /// Same ceremony as the web bridge: begin (server validates the details and
  /// binds device, generation and action), a user-verified passkey assertion
  /// from the OS provider, then finish. The renewal key is never used here.
  @override
  Future<String> addTotp(String label, String account, String secret) async {
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
    final value = {'label': label, 'account': account, 'secret': secret};
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
