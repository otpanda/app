// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';

import '../native/native_device_routes.dart' show DevicePost;
import '../native/native_passkey.dart'
    show
        PasskeyAssertionSource,
        PasskeyException,
        passkeyAssertionBody,
        passkeyRequestJson;
import 'seed_enrollment_coordinator.dart';
import 'seed_status_coordinator.dart' show SeedStatusTransport;

/// Strict HTTP adapter for the seed-sync enrollment routes (context, stepup-begin,
/// enroll-begin, enroll-finish, status-begin, status-finish). Unregistered: nothing
/// constructs it in production. It owns no session, passkey UI or native handle.
///
/// Authenticated routes go through the existing [DevicePost] (android bearer, no
/// cookies, no Origin, no query). Status routes use the credential-free
/// [SeedStatusTransport]. Every request key set is exact and every 200 body must
/// match its shape. Anything else is a failure, never a success. The server answers
/// every state failure with an opaque 409, so no failure here proves an operation
/// did not commit. This adapter retries nothing.

const seedSyncBase = '/v1/manage/seed-sync/';

/// Exact request key sets, as the server enforces them.
const seedSyncBodyKeys = <String, Set<String>>{
  'context': <String>{},
  'stepup-begin': {'installId', 'keyId', 'publicJwk'},
  'enroll-begin': {'installId', 'keyId', 'publicJwk', 'response', 'token'},
  'enroll-finish': {'signature', 'token'},
  'status-begin': {'keyId'},
  'status-finish': {'signature', 'token'},
};
const _maxBytes = {'enroll-begin': 16384};

/// True when [op] and [body] are an allowed seed-sync request.
bool seedSyncRequestAllowed(String op, Map<String, dynamic> body) {
  final keys = seedSyncBodyKeys[op];
  if (keys == null) return false;
  if (body.length != keys.length || !keys.every(body.containsKey)) return false;
  return utf8.encode(jsonEncode(body)).length <= (_maxBytes[op] ?? 4096);
}

final _token = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');
final _nonce = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _hex32 = RegExp(r'^[0-9a-f]{32}$');
final _install = RegExp(r'^[A-Za-z0-9_-]{22,64}$');
final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
const _maxSafe = 9007199254740991;

final class SeedEnrollmentHttpException implements Exception {
  const SeedEnrollmentHttpException(this.reason);

  /// One of: request, status, shape.
  final String reason;
  @override
  String toString() => 'SeedEnrollmentHttpException($reason)';
}

/// Signs the key-signed status challenge with the native key. Native builds the
/// bytes; the adapter passes only server-checked values.
typedef SeedStatusSigner = Future<String> Function({
  required String owner,
  required String keyId,
  required String challenge,
  required int expiresAt,
});

final class SeedEnrollmentHttp implements SeedEnrollmentApi {
  SeedEnrollmentHttp({
    required DevicePost post,
    required SeedStatusTransport statusTransport,
    required SeedStatusSigner signStatus,
  }) : _post = post,
       _status = statusTransport,
       _sign = signStatus;
  final DevicePost _post;
  final SeedStatusTransport _status;
  final SeedStatusSigner _sign;
  // Finish carries only a token, so the key id of its challenge is remembered
  // here to check the success body. In memory only, bounded.
  final _tokenKeys = <String, String>{};

  Never _fail(String reason) => throw SeedEnrollmentHttpException(reason);

  Future<({int status, Map<String, dynamic>? body})> _send(
    String op,
    Map<String, dynamic> body,
  ) {
    if (!seedSyncRequestAllowed(op, body)) {
      throw StateError('Seed-sync request not allowed');
    }
    return _post('$seedSyncBase$op', body);
  }

  Map<String, dynamic> _ok(
    ({int status, Map<String, dynamic>? body}) r,
    Set<String> keys,
  ) {
    if (r.status != 200) _fail('status');
    final b = r.body;
    if (b == null || b.length != keys.length || !keys.every(b.containsKey)) {
      _fail('shape');
    }
    return b;
  }

  @override
  Future<int> context() async {
    final b = _ok(await _send('context', {}), {'generation'});
    final g = b['generation'];
    if (g is! int || g < 0 || g > _maxSafe) _fail('shape');
    return g;
  }

  Map<String, dynamic> _jwk(Map<String, String> jwk) {
    if (jwk.length != 4 ||
        jwk['kty'] != 'EC' ||
        jwk['crv'] != 'P-256' ||
        !_nonce.hasMatch(jwk['x'] ?? '') ||
        !_nonce.hasMatch(jwk['y'] ?? '')) {
      throw ArgumentError('P-256 JWK required');
    }
    return {'kty': 'EC', 'crv': 'P-256', 'x': jwk['x'], 'y': jwk['y']};
  }

  void _checkIds(String installId, String keyId) {
    if (!_install.hasMatch(installId) || !_hex32.hasMatch(keyId)) {
      throw ArgumentError('invalid install or key id');
    }
  }

  @override
  Future<SeedStepUpBegin> stepUpBegin({
    required String installId,
    required String keyId,
    required Map<String, String> publicJwk,
  }) async {
    _checkIds(installId, keyId);
    final r = await _send('stepup-begin', {
      'installId': installId,
      'keyId': keyId,
      'publicJwk': _jwk(publicJwk),
    });
    if (r.status != 200) _fail('status');
    final b = r.body;
    // Same validation as every other step-up: passkeyRequestJson checks token,
    // options and expiry again, right before the OS prompt.
    if (b == null ||
        b.length != 3 ||
        !{'token', 'options', 'expiresAt'}.every(b.containsKey) ||
        b['token'] is! String ||
        !_token.hasMatch(b['token'] as String) ||
        b['options'] is! Map ||
        b['expiresAt'] is! int) {
      _fail('shape');
    }
    return SeedStepUpBegin(b['token'] as String, b);
  }

  @override
  Future<SeedEnrollChallenge> enrollBegin({
    required String installId,
    required String keyId,
    required Map<String, String> publicJwk,
    required Object assertion,
    required String token,
  }) async {
    _checkIds(installId, keyId);
    if (assertion is! Map<String, dynamic> || !_token.hasMatch(token)) {
      throw ArgumentError('assertion map and token required');
    }
    final r = await _send('enroll-begin', {
      'installId': installId,
      'keyId': keyId,
      'publicJwk': _jwk(publicJwk),
      'response': assertion,
      'token': token,
    });
    final b = _ok(r, {'token', 'challenge'});
    final c = b['challenge'];
    if (b['token'] is! String ||
        !_token.hasMatch(b['token'] as String) ||
        c is! Map ||
        c.length != 7 ||
        !{
          'ownerId',
          'keyId',
          'installId',
          'generation',
          'challenge',
          'actionDigest',
          'expiresAt',
        }.every(c.containsKey) ||
        c['ownerId'] is! String ||
        !_id.hasMatch(c['ownerId'] as String) ||
        c['keyId'] is! String ||
        !_hex32.hasMatch(c['keyId'] as String) ||
        c['installId'] is! String ||
        !_install.hasMatch(c['installId'] as String) ||
        c['generation'] is! int ||
        (c['generation'] as int) < 0 ||
        (c['generation'] as int) > _maxSafe ||
        c['challenge'] is! String ||
        !_nonce.hasMatch(c['challenge'] as String) ||
        c['actionDigest'] is! String ||
        !_hex64.hasMatch(c['actionDigest'] as String) ||
        c['expiresAt'] is! int ||
        (c['expiresAt'] as int) < 0 ||
        (c['expiresAt'] as int) > _maxSafe) {
      _fail('shape');
    }
    // The echo must be the request, otherwise the response is not for it.
    if (c['keyId'] != keyId || c['installId'] != installId) _fail('shape');
    final t = b['token'] as String;
    if (_tokenKeys.length >= 8) _tokenKeys.remove(_tokenKeys.keys.first);
    _tokenKeys[t] = keyId;
    return SeedEnrollChallenge(
      token: t,
      ownerId: c['ownerId'] as String,
      keyId: keyId,
      installId: installId,
      generation: c['generation'] as int,
      challenge: c['challenge'] as String,
      actionDigest: c['actionDigest'] as String,
      expiresAt: c['expiresAt'] as int,
    );
  }

  @override
  Future<bool> enrollFinish({
    required String signature,
    required String token,
  }) async {
    final keyId = _tokenKeys[token];
    if (keyId == null) throw StateError('finish token was not issued here');
    if (!RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(signature)) {
      throw ArgumentError('signature shape');
    }
    final r = await _send('enroll-finish', {
      'signature': signature,
      'token': token,
    });
    // A token is single use: forget it before looking at the result.
    _tokenKeys.remove(token);
    if (r.status != 200) return false;
    final b = r.body;
    // Success only for the exact {keyId} of the challenge this token belongs to.
    return b != null &&
        b.length == 1 &&
        b['keyId'] is String &&
        b['keyId'] == keyId;
  }

  @override
  Future<SeedServerKeyState> keyStatus({
    required String owner,
    required String keyId,
  }) async {
    if (!_id.hasMatch(owner) || !_hex32.hasMatch(keyId)) {
      throw ArgumentError('invalid owner or key id');
    }
    try {
      final b = await _status.post('${seedSyncBase}status-begin', {
        'keyId': keyId,
      });
      if (b.status != 200) return SeedServerKeyState.unknown;
      final begin = _object(b.body, {'token', 'challenge'});
      final c = begin?['challenge'];
      if (begin == null ||
          begin['token'] is! String ||
          !_token.hasMatch(begin['token'] as String) ||
          c is! Map<String, dynamic> ||
          c.length != 3 ||
          !{'keyId', 'challenge', 'expiresAt'}.every(c.containsKey) ||
          c['keyId'] != keyId ||
          c['challenge'] is! String ||
          !_nonce.hasMatch(c['challenge'] as String) ||
          c['expiresAt'] is! int ||
          (c['expiresAt'] as int) < 0 ||
          (c['expiresAt'] as int) > _maxSafe) {
        return SeedServerKeyState.unknown;
      }
      final signature = await _sign(
        owner: owner,
        keyId: keyId,
        challenge: c['challenge'] as String,
        expiresAt: c['expiresAt'] as int,
      );
      final f = await _status.post('${seedSyncBase}status-finish', {
        'token': begin['token'] as String,
        'signature': signature,
      });
      if (f.status != 200) return SeedServerKeyState.unknown;
      final state = _object(f.body, {'state'})?['state'];
      return switch (state) {
        'active' => SeedServerKeyState.active,
        'key-revoked' => SeedServerKeyState.revoked,
        'generation-changed' => SeedServerKeyState.generationChanged,
        _ => SeedServerKeyState.unknown,
      };
    } catch (_) {
      return SeedServerKeyState.unknown;
    }
  }

  Map<String, dynamic>? _object(String text, Set<String> keys) {
    if (text.length > 4096) return null;
    final v = jsonDecode(text);
    if (v is! Map<String, dynamic> ||
        v.length != keys.length ||
        !keys.every(v.containsKey)) {
      return null;
    }
    return v;
  }
}

/// Runs the platform passkey for the step-up begin body that [SeedEnrollmentHttp]
/// returned as `options`. The assertion is the exact body shape the server expects
/// as `response`. A cancelled prompt throws, so nothing downstream runs.
final class SeedPasskeyStepUp implements SeedPasskeyAsserter {
  SeedPasskeyStepUp(this.source, {int Function()? nowMs})
    : _now = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);
  final PasskeyAssertionSource source;
  final int Function() _now;

  @override
  Future<Object> assertStepUp(Object options) async {
    if (options is! Map<String, dynamic> || !source.available) {
      throw const PasskeyException('unavailable');
    }
    final raw = await source.get(passkeyRequestJson(options, nowMs: _now()));
    if (raw == null) throw const PasskeyException('cancelled');
    return passkeyAssertionBody(raw);
  }
}
