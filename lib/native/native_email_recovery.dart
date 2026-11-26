import 'dart:math';

import '../recovery_contract.dart';
import 'native_auth.dart' show JsonPost;
import 'native_passkey.dart';

/// Signed-out email recovery for the native client, mirroring the web calls in
/// tool/recovery-bridge.js (start, verify, sendCompletionCode, complete).
///
/// Uses the native-only routes under /auth/native/recovery/email/ (contract
/// native-settings-parity-CONTRACT-a9fb1af3: no Origin, native-origin
/// passkey verifier). NOT WIRED IN. NativeSessionBridge.recoveryAvailable
/// stays false until the contract is reviewed and proven at runtime. No
/// session is issued: after completion the person signs in with the new
/// passkey.
class NativeEmailRecovery {
  NativeEmailRecovery({
    required this.post,
    required this.creation,
    int Function()? nowMs,
    String Function()? random,
  }) : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? _secureRandom;

  final JsonPost post;
  final PasskeyCreationSource creation;
  final int Function() _now;
  final String Function() _random;

  /// Matches the server's mailbox code lifetime.
  static const bindingTtlMs = 30 * 60 * 1000;
  static final _token = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');
  static final _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _codeRe = RegExp(r'^[A-HJ-NP-Z2-9]{8}$');

  final _bindings = <String, ({String email, String binding, int at})>{};

  static String _secureRandom() {
    final r = Random.secure();
    const a =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    return List.generate(54, (_) => a[r.nextInt(a.length)]).join();
  }

  String canonical(String email) {
    final e = email.trim().toLowerCase();
    if (e.length > 254 || !_emailRe.hasMatch(e)) {
      throw const FormatException('Email required');
    }
    return e;
  }

  String humanCode(String code) {
    final c = code.replaceAll(' ', '').replaceAll('-', '').trim().toUpperCase();
    if (!_codeRe.hasMatch(c)) throw const FormatException('Code required');
    return c;
  }

  String _bind(String phase, String email) {
    final b = _random();
    _bindings[phase] = (email: email, binding: b, at: _now());
    return b;
  }

  String _binding(String phase, String email) {
    final v = _bindings[phase];
    if (v == null ||
        v.email != email ||
        _now() - v.at > bindingTtlMs ||
        v.at > _now()) {
      throw const FormatException('Request a new code');
    }
    return v.binding;
  }

  Future<Map<String, dynamic>> _call(
    String path,
    Map<String, dynamic> body, {
    bool isFinal = false,
  }) async {
    ({int status, Map<String, dynamic>? body}) r;
    try {
      r = await post(path, body);
    } catch (_) {
      throw isFinal
          ? const RecoveryOutcomeUnknown()
          : StateError('Network error');
    }
    if (isFinal && (r.status >= 500 || r.status == 408)) {
      throw const RecoveryOutcomeUnknown();
    }
    if (r.status < 200 || r.status >= 300) {
      throw isFinal ? const RecoveryRefused() : StateError('Refused');
    }
    final b = r.body;
    if (b == null) {
      throw isFinal ? const RecoveryOutcomeUnknown() : StateError('Unexpected');
    }
    return b;
  }

  Future<void> start(String email) async {
    final e = canonical(email);
    await _call('/auth/native/recovery/email/request', {
      'binding': _bind('request', e),
      'email': e,
    });
  }

  /// Returns the time the escape hatch becomes available.
  Future<DateTime> verify(String email, String code) async {
    final e = canonical(email), b = _binding('request', e);
    final v = await _call('/auth/native/recovery/email/verify', {
      'binding': b,
      'code': humanCode(code),
      'email': e,
    });
    final at = v['availableAt'];
    if (v['status'] != 'waiting' || at is! int) {
      throw StateError('Unexpected response');
    }
    _bindings.remove('request');
    return DateTime.fromMillisecondsSinceEpoch(at);
  }

  Future<void> sendCompletionCode(String email) async {
    final e = canonical(email);
    await _call('/auth/native/recovery/email/complete-code', {
      'binding': _bind('complete', e),
      'email': e,
    });
  }

  /// Completion code, then a NEW passkey. No session is issued.
  Future<void> complete(String email, String code) async {
    final e = canonical(email), b = _binding('complete', e);
    final begun = await _call('/auth/native/recovery/email/complete-begin', {
      'binding': b,
      'code': humanCode(code),
      'email': e,
    });
    _bindings.remove('complete'); // the code is consumed
    final grant = begun['grant'], ceremony = begun['ceremony'];
    if (grant is! String || !_token.hasMatch(grant) || ceremony is! Map) {
      throw StateError('Unexpected response');
    }
    final c = Map<String, dynamic>.from(ceremony);
    final raw = await creation.create(
      passkeyCreationRequestJson(c, nowMs: _now(), first: false),
    );
    if (raw == null) throw StateError('Passkey setup cancelled');
    final done = await _call('/auth/native/recovery/email/complete-finish', {
      'grant': grant,
      'response': passkeyRegistrationBody(raw),
      'token': c['token'],
    }, isFinal: true);
    if (done['status'] != 'completed') throw const RecoveryOutcomeUnknown();
  }
}
