import '../recovery_contract.dart';
import 'native_passkey.dart';

/// Bearer request to the API. [body] null means no body (GET).
typedef ManageRequest =
    Future<({int status, Map<String, dynamic>? body})> Function(
      String method,
      String path,
      Map<String, dynamic>? body,
    );

/// Native recovery, security settings, passkey rename and Google link calls,
/// per native-settings-parity-CONTRACT-a9fb1af3 (same bodies as the web
/// routes, native Bearer, no Origin). NOT WIRED IN: nothing constructs this
/// yet and no screen offers these controls. security/approve,
/// security/approve-change and recovery/approve-* are not supported on any
/// client (503 local_verification_unavailable on web too).
class NativeManageSettings {
  NativeManageSettings({
    required this.request,
    required this.passkeys,
    int Function()? nowMs,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final ManageRequest request;
  final PasskeyAssertionSource passkeys;
  final int Function() _now;

  static final _kinds = {for (final k in RecoveryKind.values) k.wire};

  Future<Map<String, dynamic>> _read(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final ({int status, Map<String, dynamic>? body}) r;
    try {
      r = await request(method, path, body);
    } catch (_) {
      throw StateError('Network error');
    }
    final b = r.body;
    if (r.status != 200 || b == null) throw StateError('Refused');
    return b;
  }

  /// The one request that may commit a change. Unreadable outcomes are
  /// unknown, never "nothing changed".
  Future<Map<String, dynamic>> _commit(
    String path,
    Map<String, dynamic> body,
  ) async {
    ({int status, Map<String, dynamic>? body}) r;
    try {
      r = await request('POST', path, body);
    } catch (_) {
      throw const RecoveryOutcomeUnknown();
    }
    if (r.status >= 500 || r.status == 408 || r.status == 0) {
      throw const RecoveryOutcomeUnknown();
    }
    if (r.status < 200 || r.status >= 300) throw const RecoveryRefused();
    final b = r.body;
    if (b == null) throw const RecoveryOutcomeUnknown();
    return b;
  }

  /// OS passkey assertion for a manage begin reply ({token, options,
  /// expiresAt}). Null when the person dismissed the prompt.
  Future<Map<String, dynamic>?> _assert(
    Map<String, dynamic> begin, {
    String expiresKey = 'expiresAt',
    int maxAllow = 50,
    int maxWindowMs = 120000,
  }) async {
    if (!passkeys.available) throw StateError('Passkeys unavailable');
    final String req;
    try {
      req = passkeyStepUpRequestJson(
        begin,
        nowMs: _now(),
        expiresKey: expiresKey,
        maxAllow: maxAllow,
        maxWindowMs: maxWindowMs,
      );
    } on PasskeyException {
      throw StateError('Invalid passkey verification');
    }
    final String? raw;
    try {
      raw = await passkeys.get(req);
    } on PasskeyException {
      return null;
    }
    if (raw == null) return null;
    try {
      return passkeyAssertionBody(raw);
    } on PasskeyException {
      throw StateError('Invalid passkey verification');
    }
  }

  Future<Map<String, dynamic>> recoveryStatus() =>
      _read('GET', '/v1/manage/recovery/status');

  Future<Map<String, dynamic>> securityStatus() =>
      _read('GET', '/v1/manage/security/status');

  /// One fresh passkey step-up bound to exactly this change. A dismissed
  /// prompt is [RecoveryRefused] (nothing was sent to finish).
  Future<void> recoveryChange(RecoveryChange c) async {
    if (!_kinds.contains(c.kind.wire)) throw const RecoveryRefused();
    final needsTarget =
        c.kind == RecoveryKind.passkeyRevoke ||
        c.kind == RecoveryKind.sessionRevoke;
    final on = c.kind == RecoveryKind.emailEscapeOn;
    final t = c.target;
    if (needsTarget && (t == null || t.isEmpty || t.length > 512)) {
      throw const RecoveryRefused();
    }
    if (on && !c.warningAccepted) throw const RecoveryRefused();
    final base = <String, dynamic>{
      'kind': c.kind.wire,
      if (needsTarget) 'target': t,
      if (on) 'warningAccepted': true,
    };
    final begin = await _beginOrRefuse('/v1/manage/recovery/begin', base);
    final response = await _assert(begin);
    if (response == null) throw const RecoveryRefused();
    await _commit('/v1/manage/recovery/finish', {
      ...base,
      'response': response,
      'token': begin['token'],
    });
  }

  Future<void> cancelRequest(String requestId) async {
    if (requestId.isEmpty || requestId.length > 128) {
      throw const RecoveryRefused();
    }
    await _commit('/v1/manage/recovery/cancel-request', {
      'requestId': requestId,
    });
  }

  /// Extra verification on new devices on/off (passkey step-up).
  Future<void> setExtraVerification(bool enabled) async {
    final base = {'enabled': enabled, 'warningAccepted': true};
    final begin = await _beginOrRefuse('/v1/manage/security/begin', base);
    final response = await _assert(begin);
    if (response == null) throw const RecoveryRefused();
    await _commit('/v1/manage/security/finish', {
      ...base,
      'token': begin['token'],
      'response': response,
    });
  }

  Future<Map<String, dynamic>> requestSecurityChange(bool enabled) => _read(
    'POST',
    '/v1/manage/security/request-change',
    {'enabled': enabled, 'warningAccepted': true},
  );

  Future<Map<String, dynamic>> consumeSecurityChange(String changeId) => _read(
    'POST',
    '/v1/manage/security/consume-change',
    {'changeId': changeId},
  );

  /// Deny a pending new-device sign-in from this enrolled device. Approve is
  /// deliberately absent: /v1/manage/security/approve answers 503
  /// local_verification_unavailable on every client until a verifier that
  /// enforces local verification exists.
  Future<void> denyPending(String pendingId) async {
    await _read('POST', '/v1/manage/security/deny', {'pendingId': pendingId});
  }

  /// Display name only: no passkey check. A null or empty label removes it.
  Future<void> renamePasskey(String credentialId, String? label) async {
    if (credentialId.isEmpty || credentialId.length > 512) {
      throw const RecoveryRefused();
    }
    String? name;
    if (label != null && label.isNotEmpty) {
      name = label.trim();
      if (name.isEmpty ||
          name.runes.length > passkeyLabelMax ||
          RegExp(r'[\u0000-\u001f\u007f-\u009f]').hasMatch(name)) {
        throw const RecoveryRefused();
      }
    }
    final done = await _commit('/v1/manage/passkey/rename', {
      'credentialId': credentialId,
      'label': name,
    });
    if (done['ok'] != true) throw const RecoveryOutcomeUnknown();
  }

  /// Google link ticket for the browser leg. [state] is 43 opaque chars.
  Future<({String ticket, int expiresAt})> googleLinkTicket(
    String state,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(state)) {
      throw StateError('Invalid state');
    }
    final b = await _read('POST', '/v1/manage/google/link/ticket', {
      'state': state,
    });
    final t = b['ticket'], x = b['expiresAt'];
    if (t is! String || t.isEmpty || t.length > 512 || x is! int) {
      throw StateError('Unexpected response');
    }
    return (ticket: t, expiresAt: x);
  }

  /// After the browser leg returns the link-only continuation: passkey
  /// step-up links the identity. No session is issued (already signed in).
  Future<void> googleLinkFinish(String continuation) async {
    if (continuation.isEmpty || continuation.length > 512) {
      throw const RecoveryRefused();
    }
    final begin = await _beginOrRefuse('/v1/manage/google/link/begin', {
      'continuation': continuation,
    });
    final response = await _assert(
      begin,
      expiresKey: 'expires_at',
      maxAllow: 20,
      maxWindowMs: 300000,
    );
    if (response == null) throw const RecoveryRefused();
    final done = await _commit('/v1/manage/google/link/finish', {
      'continuation': continuation,
      'token': begin['token'],
      'response': response,
    });
    if (done['status'] != 'linked') throw const RecoveryOutcomeUnknown();
  }

  Future<Map<String, dynamic>> _beginOrRefuse(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await _read('POST', path, body);
    } on StateError {
      throw const RecoveryRefused();
    }
  }
}
