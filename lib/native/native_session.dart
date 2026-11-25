import 'package:flutter/foundation.dart';

import 'native_auth.dart';
import 'native_passkey.dart';

enum NativeSessionPhase {
  unknown,
  signedOut,
  signedIn,

  /// Renewal failed twice with fresh challenges. Show sign-in. This is not
  /// proof of revocation and the Keystore key is kept.
  signInRequired,

  /// Outage, rate limit or network: local state kept, retry later.
  offline,
}

/// Holds the current native session and drives renewal. No UI, no secrets
/// beyond the in-memory access handle.
class NativeSessionController extends ChangeNotifier {
  NativeSessionController(this.auth, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final NativeAuth auth;
  final DateTime Function() _now;

  NativeSessionPhase _phase = NativeSessionPhase.unknown;
  NativeSession? _session;
  String? lastError;

  NativeSessionPhase get phase => _phase;
  NativeSession? get session => _session;

  void _set(NativeSessionPhase p, [NativeSession? s, String? err]) {
    _phase = p;
    _session = s;
    lastError = err;
    notifyListeners();
  }

  /// App start: renew from the Keystore key if a device id is stored.
  Future<void> start() => _renew();

  /// Renews now (single-flight inside NativeAuth), e.g. after an API 401.
  Future<void> forceRenew() => _renew();

  Future<void> _renew() async {
    try {
      final s = await auth.renew();
      s == null
          ? _set(NativeSessionPhase.signedOut)
          : _set(NativeSessionPhase.signedIn, s);
    } on NativeAuthException catch (e) {
      if (e.kind == 'invalid_grant') {
        _set(NativeSessionPhase.signInRequired, null, e.kind);
      } else {
        _set(NativeSessionPhase.offline, _session, e.kind);
      }
    }
  }

  /// Returns a bearer valid for at least 60 s, renewing if needed. Null when
  /// there is none (caller shows sign-in or offline state).
  Future<String?> accessToken() async {
    final s = _session;
    final fresh =
        s != null && s.accessExpiresAt - _now().millisecondsSinceEpoch > 60000;
    if (!fresh) await _renew();
    return _phase == NativeSessionPhase.signedIn ? _session?.access : null;
  }

  Future<void> signInWithBrowser({String? provider, bool? remember}) => _signIn(
    () => auth.signInWithBrowser(provider: provider, remember: remember),
  );

  Future<void> signupEmail(String email) =>
      _step(() => auth.signupEmail(email));
  Future<void> signupBegin(String email, String code) =>
      _step(() => auth.signupBegin(email, code));
  Future<void> signupAbort() => _step(auth.signupAbort);
  Future<void> signupFinish(PasskeyCreationSource source) =>
      _signIn(() => auth.signupFinish(source));

  Future<void> googleLinkAbort() => _step(auth.googleLinkAbort);
  Future<void> googleLinkFinish(PasskeyAssertionSource source) =>
      _signIn(() => auth.googleLinkFinish(source));

  Future<void> _step(Future<void> Function() f) async {
    try {
      lastError = null;
      await f();
    } on NativeAuthException catch (e) {
      lastError = e.kind;
    }
    notifyListeners();
  }

  /// The first passkey or device key used the one-time grant: stop offering it.
  void consumeEnrollGrant() {
    final s = _session;
    if (s == null || s.enrollGrant == null) return;
    _session = NativeSession(s.deviceId, s.access, s.accessExpiresAt);
    notifyListeners();
  }

  Future<void> signInWithPasskey() => _signIn(auth.signInWithPasskey);

  /// Falls back to the browser when the account needs it (409).
  Future<void> signInWithGoogle({bool? remember}) => _signIn(() async {
    try {
      return await auth.signInWithGoogle(remember: true);
    } on NativeAuthException catch (e) {
      if (e.kind == 'browser_required') {
        return auth.signInWithBrowser(provider: 'google', remember: true);
      }
      rethrow;
    }
  });

  Future<void> _signIn(Future<NativeSession> Function() f) async {
    try {
      _set(NativeSessionPhase.signedIn, await f());
    } on NativeAuthException catch (e) {
      // Cancel or failure leaves the previous state, not a false sign-out.
      lastError = e.kind;
      notifyListeners();
    }
  }

  /// Server-confirmed only: local material goes only after logout 204.
  Future<void> signOut() async {
    try {
      await auth.logout();
      _set(NativeSessionPhase.signedOut);
    } on NativeAuthException catch (e) {
      lastError = e.kind;
      notifyListeners();
    }
  }
}
