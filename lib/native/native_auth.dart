import 'dart:async';
import 'dart:typed_data';

import 'native_handoff.dart';
import 'native_passkey.dart';
import 'native_signing.dart';

/// Platform adapters. Real implementations (AndroidKeystore EC P-256 key,
/// Custom Tab + App Link, Credential Manager Google sign-in) live behind
/// these so the state machine is testable with fakes.
abstract class NativeKeystore {
  /// The active renewal key's public point (65 bytes, 0x04 || X || Y),
  /// created only if none exists. Never replaces a valid key.
  Future<Uint8List> ensureKey();

  /// Generates a NEW pending key (the active key stays valid) and returns
  /// its public point. Used by every new sign-in.
  Future<Uint8List> beginNewKey();

  /// After the server accepted the new key (exchange/complete 200): the
  /// pending key becomes active and the old key is deleted.
  Future<void> commitNewKey();

  /// Drops the pending key; the active key is untouched.
  Future<void> discardNewKey();

  /// True when a pending key exists (a sign-in was interrupted between the
  /// server accepting the new key and the local commit).
  Future<bool> hasPendingKey();

  /// ECDSA-SHA256 over [message], DER encoded (as Keystore returns it).
  Future<Uint8List> signDer(Uint8List message, {bool pending = false});
  Future<void> deleteKey();
}

abstract class BrowserHandoff {
  /// Opens [url] in a Custom Tab and completes with the App Link URI that
  /// returns to the app, or null if the user cancelled.
  Future<Uri?> run(Uri url);
}

abstract class GoogleIdTokenSource {
  bool get available;

  /// Native Google sign-in with the server-issued [nonce]. Null if cancelled.
  Future<String?> idToken({required String nonce});
}

abstract class NativeSecureStore {
  Future<String?> readDeviceId();
  Future<void> writeDeviceId(String id);
  Future<void> clear();
}

/// Opaque Google recognition secret (server-issued, <=200 chars). Hardware
/// Keystore-backed on Android, never in plain prefs or logs.
abstract class RecognitionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class NativeAuthException implements Exception {
  const NativeAuthException(this.kind);

  /// invalid_grant, invalid_request, rate_limited, browser_required,
  /// unavailable, network, cancelled, protocol.
  final String kind;
  @override
  String toString() => 'NativeAuthException($kind)';
}

class NativeSession {
  const NativeSession(
    this.deviceId,
    this.access,
    this.accessExpiresAt, {
    this.enrollGrant,
    this.grantAtMs,
  });
  final String deviceId;
  final String access;
  final int accessExpiresAt;

  /// One-time first-enrollment grant (bearer secret, about 120 s). Only the
  /// browser exchange and Google complete responses may carry it. Memory only:
  /// never persist or log it. Absent unless the server issued one.
  final String? enrollGrant;

  /// Local time the grant arrived, to hide first-passkey set-up once it is
  /// stale (the server enforces the real expiry).
  final int? grantAtMs;
}

/// JSON POST transport. Must send no cookies and no Origin header.
typedef JsonPost = Future<({int status, Map<String, dynamic>? body})> Function(
  String path,
  Map<String, dynamic> body,
);

class NativeAuth {
  NativeAuth({
    required this.post,
    required this.keystore,
    required this.browser,
    required this.google,
    required this.store,
    required this.apiOrigin,
    required this.launchUrl,
    this.passkeys,
    this.recognition,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final JsonPost post;
  final NativeKeystore keystore;
  final BrowserHandoff browser;
  final GoogleIdTokenSource google;
  final NativeSecureStore store;
  final String apiOrigin;

  /// OS passkey (Credential Manager). Null or unavailable: no OS passkey.
  final PasskeyAssertionSource? passkeys;
  final RecognitionStore? recognition;
  final int Function() _now;

  /// Builds the URL the Custom Tab opens (the Pages app, which signs in and
  /// continues to /auth/native/approve) for a PKCE challenge and state.
  final Uri Function(String challenge, String state) launchUrl;

  Uri get _redirect => Uri.parse('$apiOrigin/app-return');

  Future<String> _newRenewalKey() async {
    final p = await keystore.beginNewKey();
    if (p.length != 65 || p[0] != 4) {
      throw const NativeAuthException('protocol');
    }
    return encodeRenewalKey(p.sublist(1, 33), p.sublist(33));
  }

  NativeAuthException _fail(int status, Map<String, dynamic>? b) {
    final e = b?['error'];
    if (status == 429) return const NativeAuthException('rate_limited');
    if (status == 409 && e == 'browser_required') {
      return const NativeAuthException('browser_required');
    }
    if (status == 503) return const NativeAuthException('unavailable');
    if (status == 400) return const NativeAuthException('invalid_request');
    if (status == 401) return const NativeAuthException('invalid_grant');
    return const NativeAuthException('protocol');
  }

  static final _grantShape = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');

  NativeSession _session(
    Map<String, dynamic>? b, [
    String? knownDevice,
    bool allowGrant = false,
  ]) {
    final d = b?['device_id'] ?? knownDevice,
        a = b?['access'],
        x = b?['access_expires_at'];
    if (d is! String || a is! String || x is! int) {
      throw const NativeAuthException('protocol');
    }
    // Absent key = no grant. Present must be a well-formed token (never null);
    // renewal responses never carry one, so it is ignored there.
    String? grant;
    if (allowGrant && (b?.containsKey('enroll_grant') ?? false)) {
      final g = b!['enroll_grant'];
      if (g is! String || !_grantShape.hasMatch(g)) {
        throw const NativeAuthException('protocol');
      }
      grant = g;
    }
    return NativeSession(
      d,
      a,
      x,
      enrollGrant: grant,
      grantAtMs: grant == null ? null : _now(),
    );
  }

  Future<({int status, Map<String, dynamic>? body})> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      return await post(path, body);
    } on NativeAuthException {
      rethrow;
    } catch (_) {
      throw const NativeAuthException('network');
    }
  }

  /// Browser path (the only path on the F-Droid flavor).
  /// [provider] 'google' asks Pages to start Google directly; [remember]
  /// carries the shared screen's checkbox. Both are optional fragment params.
  Future<NativeSession> signInWithBrowser({
    String? provider,
    bool? remember,
  }) async {
    final pkce = PkcePair.generate();
    final state = generateState();
    return _withNewKey((key) async {
      var url = launchUrl(pkce.challenge, state);
      if (provider != null || remember != null) {
        final extra = [
          if (provider != null) 'provider=$provider',
          if (provider == 'google') 'remember=1',
        ].join('&');
        url = url.replace(fragment: '${url.fragment}&$extra');
      }
      final ret = await browser.run(url);
      if (ret == null) throw const NativeAuthException('cancelled');
      final parsed = parseAppReturn(
        ret,
        apiOrigin: apiOrigin,
        expectedState: state,
      );
      if (parsed == null) throw const NativeAuthException('protocol');
      return _post('/auth/native/exchange', {
        'code': parsed.code,
        'verifier': pkce.verifier,
        'redirect_uri': _redirect.toString(),
        'renewal_key': key,
      });
    });
  }

  /// OS passkey sign-in (discoverable, user-verified). The ceremony is bound
  /// to the new renewal key. Cancel leaves everything as it was. Every server
  /// verification failure is an opaque 401 (invalid_grant).
  Future<NativeSession> signInWithPasskey() async {
    final source = passkeys;
    if (source == null || !source.available) {
      throw const NativeAuthException('unavailable');
    }
    return _withNewKey((key) async {
      final b = await _post('/auth/native/passkey/begin', {'renewal_key': key});
      if (b.status != 200 || b.body == null) throw _fail(b.status, b.body);
      final String request;
      try {
        request = passkeyLoginRequestJson(b.body!, nowMs: _now());
      } on PasskeyException {
        throw const NativeAuthException('protocol');
      }
      final String? raw;
      try {
        raw = await source.get(request);
      } on PasskeyException catch (e) {
        throw NativeAuthException(
          e.code == 'cancelled' ? 'cancelled' : 'passkey_failed',
        );
      }
      if (raw == null) throw const NativeAuthException('cancelled');
      final Map<String, dynamic> response;
      try {
        response = passkeyAssertionBody(raw);
      } on PasskeyException {
        throw const NativeAuthException('protocol');
      }
      // Discoverable sign-in must carry the user handle.
      if ((response['response'] as Map)['userHandle'] is! String) {
        throw const NativeAuthException('protocol');
      }
      return _post('/auth/native/passkey/complete', {
        'renewal_key': key,
        'token': b.body!['token'],
        'response': response,
      });
    });
  }

  /// Google flavor only. 409 browser_required means the account needs the
  /// browser path; callers fall back to [signInWithBrowser].
  Future<NativeSession> signInWithGoogle({bool? remember}) async {
    if (!google.available) throw const NativeAuthException('unavailable');
    String? issued;
    final session = await _withNewKey((key) async {
      final b = await _post('/auth/native/google/begin', const {});
      if (b.status != 200 || b.body?['nonce'] is! String) {
        throw _fail(b.status, b.body);
      }
      final token = await google.idToken(nonce: b.body!['nonce'] as String);
      if (token == null) throw const NativeAuthException('cancelled');
      String? known;
      try {
        known = await recognition?.read();
      } catch (_) {
        known = null;
      }
      final r = await _post('/auth/native/google/complete', {
        'id_token': token,
        'renewal_key': key,
        'remember': true,
        if (known != null && known.isNotEmpty && known.length <= 200)
          'recognition': known,
      });
      final n = r.body?['recognition'];
      if (r.status == 200 && n is String && n.isNotEmpty && n.length <= 200) {
        issued = n;
      }
      return r;
    });
    // Storage failure must not undo a completed sign-in.
    final v = issued;
    if (v != null) {
      try {
        await recognition?.write(v);
      } catch (_) {}
    }
    return session;
  }

  /// New-key sign-in: the previous valid key survives until the server
  /// answers 200; any failure or cancel discards only the pending key.
  bool _signingIn = false;

  Future<NativeSession> _withNewKey(
    Future<({int status, Map<String, dynamic>? body})> Function(String key)
    step,
  ) async {
    // One sign-in at a time: a second would rotate or delete the first's
    // pending key.
    if (_signingIn) throw const NativeAuthException('busy');
    _signingIn = true;
    var accepted = false;
    try {
      final key = await _newRenewalKey();
      try {
        final r = await step(key);
        if (r.status != 200) throw _fail(r.status, r.body);
        final s = _session(r.body, null, true);
        accepted = true;
        // Device id first, then commit: a crash in between leaves a pending
        // key that matches the stored device (see renew fallback). The
        // reverse order would strand a device id that no stored key matches.
        await store.writeDeviceId(s.deviceId);
        await keystore.commitNewKey();
        return s;
      } catch (_) {
        if (!accepted) await keystore.discardNewKey();
        rethrow;
      }
    } finally {
      _signingIn = false;
    }
  }

  Future<({String nonce, int expiresAt})> _challenge(
    String deviceId,
    NativePurpose purpose,
  ) async {
    final r = await _post('/auth/native/challenge', {
      'device_id': deviceId,
      'purpose': purpose.name,
    });
    final n = r.body?['nonce'], x = r.body?['expires_at'];
    if (r.status != 200 ||
        r.body?['device_id'] != deviceId ||
        n is! String ||
        x is! int) {
      throw _fail(r.status, r.body);
    }
    return (nonce: n, expiresAt: x);
  }

  Future<Map<String, dynamic>> _signed(
    NativePurpose p,
    String deviceId, {
    bool pending = false,
  }) async {
    final c = await _challenge(deviceId, p);
    final der = await keystore.signDer(
      nativeMessage(
        purpose: p,
        deviceId: deviceId,
        nonce: c.nonce,
        expiresAt: c.expiresAt,
      ),
      pending: pending,
    );
    return {
      'device_id': deviceId,
      'nonce': c.nonce,
      'expires_at': c.expiresAt,
      'signature': base64UrlNoPad(ecdsaDerToRaw(der)),
    };
  }

  /// Killed-app renewal. Null when nothing is stored (signed out). A 401 may
  /// be an expired or replayed nonce, not revocation, so it is retried once
  /// with a fresh challenge and then surfaced as invalid_grant. Local key and
  /// device id are never deleted on an ambiguous failure.
  Future<NativeSession?>? _renewing;

  /// Single-flight: parallel callers share one renewal (two parallel renews
  /// would spend each other's nonce).
  Future<NativeSession?> renew() {
    final f = _renewing ??= _renew().whenComplete(() => _renewing = null);
    return f;
  }

  Future<NativeSession?> _renew() async {
    final id = await store.readDeviceId();
    if (id == null) return null;
    var r = await _post(
      '/auth/native/renew',
      await _signed(NativePurpose.renew, id),
    );
    if (r.status == 401) {
      r = await _post(
        '/auth/native/renew',
        await _signed(NativePurpose.renew, id),
      );
    }
    if (r.status == 401 && await keystore.hasPendingKey()) {
      // Interrupted sign-in: the server may hold the pending key. Try it once;
      // on success it becomes the active key. Nothing is deleted on failure.
      final p = await _post(
        '/auth/native/renew',
        await _signed(NativePurpose.renew, id, pending: true),
      );
      if (p.status == 200) {
        final s = _session(p.body, id);
        await keystore.commitNewKey();
        return s;
      }
    }
    if (r.status != 200) throw _fail(r.status, r.body);
    return _session(r.body, id);
  }

  // ---- Native signup (email code, then a new passkey). Install-bound: the
  // same renewal key goes to all three calls, so one pending key is held for
  // the whole flow and sign-in is blocked ('busy') until it ends.
  String? _signupKey;
  String? _signupToken;
  Map<String, dynamic>? _signupOptions;
  int _signupExpires = 0;
  bool _signupCodeInvalid = false;

  /// 'email-code', 'code-invalid', 'signup-ready' or null (not signing up).
  String? get signupStage {
    if (_signupKey == null) return null;
    if (_signupToken != null) return 'signup-ready';
    return _signupCodeInvalid ? 'code-invalid' : 'email-code';
  }

  Future<void> signupAbort() async {
    final held = _signupKey != null;
    _signupKey = null;
    _signupToken = null;
    _signupOptions = null;
    _signupCodeInvalid = false;
    if (held) {
      try {
        await keystore.discardNewKey();
      } finally {
        _signingIn = false;
      }
    }
  }

  /// Sends the code. The server always answers 202 (no existence oracle).
  Future<void> signupEmail(String email) async {
    if (_signupKey == null) {
      if (_signingIn) throw const NativeAuthException('busy');
      _signingIn = true;
      try {
        _signupKey = await _newRenewalKey();
      } catch (_) {
        _signingIn = false;
        rethrow;
      }
    }
    final r = await _post('/auth/native/signup/email', {
      'email': email,
      'renewal_key': _signupKey,
    });
    if (r.status != 202) throw _fail(r.status, r.body);
    _signupToken = null;
    _signupCodeInvalid = false;
  }

  /// Verifies the emailed code. An existing account ends the flow and says so.
  Future<void> signupBegin(String email, String code) async {
    final key = _signupKey;
    if (key == null) throw const NativeAuthException('protocol');
    final r = await _post('/auth/native/signup/begin', {
      'email': email,
      'email_code': code,
      'renewal_key': key,
    });
    if (r.status == 401) {
      _signupCodeInvalid = true;
      return;
    }
    if (r.status != 200 || r.body == null) throw _fail(r.status, r.body);
    if (r.body!['existing'] == true) {
      await signupAbort();
      throw const NativeAuthException('signup_existing');
    }
    final t = r.body!['token'],
        o = r.body!['options'],
        x = r.body!['expires_at'];
    if (t is! String || o is! Map<String, dynamic> || x is! int) {
      await signupAbort();
      throw const NativeAuthException('protocol');
    }
    _signupToken = t;
    _signupOptions = o;
    _signupExpires = x;
    _signupCodeInvalid = false;
  }

  /// OS passkey creation, then the finish call. Cancel keeps the ceremony.
  Future<NativeSession> signupFinish(PasskeyCreationSource source) async {
    final key = _signupKey, token = _signupToken, options = _signupOptions;
    if (key == null || token == null || options == null) {
      throw const NativeAuthException('protocol');
    }
    if (!source.available) throw const NativeAuthException('unavailable');
    final String request;
    try {
      request = passkeyCreationRequestJson(
        {'token': token, 'options': options, 'expiresAt': _signupExpires},
        nowMs: _now(),
        first: true,
        strictToken: false,
      );
    } on PasskeyException {
      await signupAbort();
      throw const NativeAuthException('protocol');
    }
    final String? raw;
    try {
      raw = await source.create(request);
    } on PasskeyException {
      throw const NativeAuthException('passkey_failed');
    }
    if (raw == null) throw const NativeAuthException('cancelled');
    final Map<String, dynamic> response;
    try {
      response = passkeyRegistrationBody(raw);
    } on PasskeyException {
      await signupAbort();
      throw const NativeAuthException('protocol');
    }
    // Once finish is sent the account may exist even if the answer is lost or
    // refused (for example a session issue failed after creation). Never
    // repeat creation: end the attempt and point to passkey sign-in.
    ({int status, Map<String, dynamic>? body}) r;
    try {
      r = await post('/auth/native/signup/finish', {
        'renewal_key': key,
        'token': token,
        'response': response,
      });
    } catch (_) {
      r = (status: 0, body: null);
    }
    if (r.status != 200) {
      await signupAbort();
      throw const NativeAuthException('signup_unconfirmed');
    }
    final s = _session(r.body, null, false);
    await store.writeDeviceId(s.deviceId);
    await keystore.commitNewKey();
    _signupKey = null;
    _signupToken = null;
    _signupOptions = null;
    _signingIn = false;
    return s;
  }

  /// Local material is removed only after the server confirmed with 204.
  /// Any other answer, including 401, leaves it so logout can be retried.
  Future<void> logout() async {
    final id = await store.readDeviceId();
    if (id == null) return;
    final r = await _post(
      '/auth/native/logout',
      await _signed(NativePurpose.logout, id),
    );
    if (r.status != 204) throw _fail(r.status, r.body);
    await store.clear();
    await keystore.deleteKey();
  }
}
