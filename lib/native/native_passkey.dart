import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

const passkeyChannel = MethodChannel('app.otpanda/passkey');

class PasskeyException implements Exception {
  const PasskeyException(this.code);
  final String code;
  @override
  String toString() => 'PasskeyException($code)';
}

/// Provider of a user-verified passkey assertion for a server ceremony.
/// It is the only step-up. The Keystore renewal key is never used for it.
/// Creates a passkey (Credential Manager createCredential).
abstract interface class PasskeyCreationSource {
  bool get available;

  /// [requestJson] is the Credential Manager registration request. Returns the
  /// RegistrationResponseJSON, or null when the user cancelled.
  Future<String?> create(String requestJson);
}

abstract interface class PasskeyAssertionSource {
  bool get available;

  /// [requestJson] is the WebAuthn request options JSON. Returns the
  /// authentication response JSON, or null when the user cancelled.
  Future<String?> get(String requestJson);
}

/// Credential Manager on the google flavor. On F-Droid there is no native
/// side, [probe] stays false and the add action stays hidden.
class AndroidPasskeySource
    implements PasskeyAssertionSource, PasskeyCreationSource {
  AndroidPasskeySource({MethodChannel channel = passkeyChannel}) : _c = channel;
  final MethodChannel _c;
  bool _available = false;

  @override
  bool get available => _available;

  Future<void> probe() async {
    try {
      _available = await _c.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
  }

  @override
  Future<String?> get(String requestJson) async {
    try {
      return await _c.invokeMethod<String>('get', {'requestJson': requestJson});
    } on PlatformException catch (e) {
      throw PasskeyException(e.code);
    }
  }

  @override
  Future<String?> create(String requestJson) async {
    try {
      return await _c.invokeMethod<String>('create', {
        'requestJson': requestJson,
      });
    } on PlatformException catch (e) {
      throw PasskeyException(e.code);
    }
  }
}

final _b64url = RegExp(r'^[A-Za-z0-9_-]+$');

/// Validates a begin response exactly like tool/session-bootstrap.js and
/// returns the Credential Manager request JSON. Throws on anything unexpected.
String passkeyRequestJson(
  Map<String, dynamic> begin, {
  required int nowMs,
  String rpId = 'otpanda.github.io',
}) {
  final o = begin['options'];
  final token = begin['token'];
  final exp = begin['expiresAt'];
  if (token is! String ||
      !RegExp(r'^otpda_[A-Za-z0-9_-]{55}$').hasMatch(token) ||
      o is! Map ||
      o['rpId'] != rpId ||
      o['userVerification'] != 'required' ||
      o['challenge'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(o['challenge'] as String) ||
      o['allowCredentials'] is! List ||
      (o['allowCredentials'] as List).length > 50 ||
      exp is! int ||
      exp <= nowMs ||
      exp > nowMs + 120000) {
    throw const PasskeyException('invalid');
  }
  final allow = <Map<String, String>>[];
  for (final v in o['allowCredentials'] as List) {
    final id = v is Map ? v['id'] : null;
    if (id is! String || id.isEmpty || !_b64url.hasMatch(id)) {
      throw const PasskeyException('invalid');
    }
    allow.add({'type': 'public-key', 'id': id});
  }
  return jsonEncode({
    'rpId': rpId,
    'challenge': o['challenge'],
    'userVerification': 'required',
    'timeout': (exp - nowMs).clamp(1, 120000),
    'allowCredentials': allow,
  });
}

/// Maps the Credential Manager response onto the shape the web bridge posts.
Map<String, dynamic> passkeyAssertionBody(String responseJson) {
  final j = jsonDecode(responseJson);
  final r = j is Map ? j['response'] : null;
  if (j is! Map ||
      r is! Map ||
      j['type'] != 'public-key' ||
      j['id'] is! String ||
      j['rawId'] is! String ||
      r['clientDataJSON'] is! String ||
      r['authenticatorData'] is! String ||
      r['signature'] is! String) {
    throw const PasskeyException('invalid');
  }
  return {
    'id': j['id'],
    'rawId': j['rawId'],
    'type': 'public-key',
    'clientExtensionResults': const <String, dynamic>{},
    'response': {
      'clientDataJSON': r['clientDataJSON'],
      'authenticatorData': r['authenticatorData'],
      'signature': r['signature'],
      'userHandle': r['userHandle'] is String ? r['userHandle'] : null,
    },
  };
}

/// Validates /auth/native/passkey/begin and returns the Credential Manager
/// request JSON (discoverable: no allowCredentials). Throws on anything
/// unexpected. Contract: native-passkey-signin (begin returns
/// {token, options, expires_at}); proposed, not deployed.
String passkeyLoginRequestJson(
  Map<String, dynamic> begin, {
  required int nowMs,
  String rpId = 'otpanda.github.io',
}) {
  final o = begin['options'];
  final token = begin['token'];
  final exp = begin['expires_at'];
  if (token is! String ||
      token.isEmpty ||
      token.length > 512 ||
      o is! Map ||
      o['rpId'] != rpId ||
      o['userVerification'] != 'required' ||
      o['challenge'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(o['challenge'] as String) ||
      (o['allowCredentials'] != null &&
          !(o['allowCredentials'] is List &&
              (o['allowCredentials'] as List).isEmpty)) ||
      exp is! int ||
      exp <= nowMs ||
      exp > nowMs + 300000) {
    throw const PasskeyException('invalid');
  }
  return jsonEncode({
    'rpId': rpId,
    'challenge': o['challenge'],
    'userVerification': 'required',
    'timeout': (exp - nowMs).clamp(1, 120000),
    'allowCredentials': const <Map<String, String>>[],
  });
}

final _otpToken = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');

/// Validates a register-begin / first-passkey begin response exactly like
/// tool/session-bootstrap.js (addPasskey, firstPasskey) and returns the
/// Credential Manager create request JSON. [first] means no exclusions.
/// Throws PasskeyException('invalid') on anything unexpected.
String passkeyCreationRequestJson(
  Map<String, dynamic> begin, {
  required int nowMs,
  required bool first,
  bool strictToken = true,
  String rpId = 'otpanda.github.io',
}) {
  final o = begin['options'];
  final token = begin['token'];
  final exp = begin['expiresAt'];
  if (token is! String ||
      (strictToken
          ? !_otpToken.hasMatch(token)
          : token.isEmpty || token.length > 512) ||
      o is! Map ||
      o['rp'] is! Map ||
      (o['rp'] as Map)['id'] != rpId ||
      (o['rp'] as Map)['name'] != 'OTPanda' ||
      o['challenge'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(o['challenge'] as String) ||
      exp is! int ||
      exp <= nowMs ||
      exp > nowMs + 120000 ||
      o['authenticatorSelection'] is! Map ||
      (o['authenticatorSelection'] as Map)['userVerification'] != 'required' ||
      o['excludeCredentials'] is! List ||
      (o['excludeCredentials'] as List).length > (first ? 0 : 10) ||
      o['user'] is! Map) {
    throw const PasskeyException('invalid');
  }
  final u = o['user'] as Map;
  if (u['id'] is! String ||
      !_b64url.hasMatch(u['id'] as String) ||
      u['name'] is! String ||
      u['displayName'] is! String) {
    throw const PasskeyException('invalid');
  }
  final exclude = <Map<String, String>>[];
  for (final v in o['excludeCredentials'] as List) {
    final id = v is Map ? v['id'] : null;
    if (v is! Map ||
        v['type'] != 'public-key' ||
        id is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,1400}$').hasMatch(id)) {
      throw const PasskeyException('invalid');
    }
    exclude.add({'type': 'public-key', 'id': id});
  }
  return jsonEncode({
    'rp': {'id': rpId, 'name': 'OTPanda'},
    'user': {'id': u['id'], 'name': u['name'], 'displayName': u['displayName']},
    'challenge': o['challenge'],
    'pubKeyCredParams': const [
      {'type': 'public-key', 'alg': -7},
      {'type': 'public-key', 'alg': -257},
    ],
    'timeout': (exp - nowMs).clamp(1, 120000),
    'attestation': 'none',
    'authenticatorSelection': {
      'residentKey': 'required',
      'userVerification': 'required',
    },
    'excludeCredentials': exclude,
  });
}

/// Maps the Credential Manager registration response onto the body the web
/// bridge posts to register-finish / first-passkey finish.
Map<String, dynamic> passkeyRegistrationBody(String responseJson) {
  final j = jsonDecode(responseJson);
  final r = j is Map ? j['response'] : null;
  if (j is! Map ||
      r is! Map ||
      j['type'] != 'public-key' ||
      j['id'] is! String ||
      j['rawId'] is! String ||
      r['clientDataJSON'] is! String ||
      r['attestationObject'] is! String) {
    throw const PasskeyException('invalid');
  }
  final t = r['transports'];
  return {
    'id': j['id'],
    'rawId': j['rawId'],
    'type': 'public-key',
    'clientExtensionResults': const <String, dynamic>{},
    'response': {
      'clientDataJSON': r['clientDataJSON'],
      'attestationObject': r['attestationObject'],
      'transports': t is List ? t.whereType<String>().toList() : <String>[],
    },
  };
}
