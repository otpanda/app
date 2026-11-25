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
abstract interface class PasskeyAssertionSource {
  bool get available;

  /// [requestJson] is the WebAuthn request options JSON. Returns the
  /// authentication response JSON, or null when the user cancelled.
  Future<String?> get(String requestJson);
}

/// Credential Manager on the google flavor. On F-Droid there is no native
/// side, [probe] stays false and the add action stays hidden.
class AndroidPasskeySource implements PasskeyAssertionSource {
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
