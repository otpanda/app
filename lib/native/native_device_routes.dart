import 'dart:convert';
import 'dart:typed_data';

import 'native_device_proof.dart';

/// Authenticated android JSON POST: bearer from the native session, no cookies,
/// no Origin, no query. The caller (bridge) enforces the path allowlist.
typedef DevicePost =
    Future<({int status, Map<String, dynamic>? body})> Function(
      String path,
      Map<String, dynamic> body,
    );

/// The only device-key paths a native client may POST (v8, no query string).
const deviceKeyPaths = {
  '/v1/manage/device-key/enroll-begin',
  '/v1/manage/device-key/enroll-finish',
  '/v1/manage/device-key/enroll-status',
  '/v1/manage/device-key/adopt-begin',
  '/v1/manage/device-key/adopt-finish',
  '/v1/manage/device-key/add-request',
  '/v1/manage/device-key/add-begin',
  '/v1/manage/device-key/add-finish',
  '/v1/manage/approval/status',
  '/v1/manage/approval/approve-begin',
  '/v1/manage/approval/approve-finish',
};

/// Exact request key sets (the server rejects anything else with 400).
const deviceKeyBodyKeys = {
  '/v1/manage/device-key/enroll-begin': {'publicJwk', 'grant'},
  '/v1/manage/device-key/enroll-finish': {'grant', 'token', 'signature'},
  '/v1/manage/device-key/enroll-status': {'digest'},
  '/v1/manage/device-key/adopt-begin': {'digest'},
  '/v1/manage/device-key/adopt-finish': {'digest', 'token', 'signature'},
  '/v1/manage/device-key/add-request': {'publicJwk'},
  '/v1/manage/device-key/add-begin': {'changeId'},
  '/v1/manage/device-key/add-finish': {'changeId', 'token', 'signature'},
  '/v1/manage/approval/status': <String>{},
  '/v1/manage/approval/approve-begin': {'changeId', 'keyId'},
  '/v1/manage/approval/approve-finish': {'changeId', 'token', 'signature'},
};

/// True when [path] and [body] are an allowed device-key request.
bool deviceKeyRequestAllowed(String path, Map<String, dynamic> body) {
  final keys = deviceKeyBodyKeys[path];
  if (keys == null || path.contains('?')) return false;
  if (body.length != keys.length || !keys.every(body.containsKey)) return false;
  return utf8.encode(jsonEncode(body)).length <= 4096;
}

final _tokenShape = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');
final _b64u43 = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');

String b64uNoPad(Uint8List b) => base64Url.encode(b).replaceAll('=', '');

EnrollChallenge? parseDeviceChallenge(Map<String, dynamic>? b, String purpose) {
  if (b == null) return null;
  final t = b['token'], c = b['challenge'];
  if (t is! String || !_tokenShape.hasMatch(t) || c is! Map) return null;
  final o = c['ownerId'], k = c['keyId'], g = c['generation'];
  final pu = c['purpose'], ad = c['actionDigest'], ch = c['challenge'];
  final ex = c['expiresAt'];
  if (o is! String || o.isEmpty || k is! String || k.isEmpty || g is! int) {
    return null;
  }
  if (pu != purpose ||
      ad is! String ||
      !_hex64.hasMatch(ad) ||
      ch is! String ||
      !_b64u43.hasMatch(ch) ||
      ex is! int) {
    return null;
  }
  return EnrollChallenge(
    token: t,
    ownerId: o,
    keyId: k,
    generation: g,
    challenge: ch,
    actionDigest: ad,
    expiresAt: ex,
    purpose: pu as String,
  );
}

/// First-enrollment route clients. Strict parsers: anything unexpected on a
/// 200 is never success. [grant] is the in-memory enroll grant (bearer secret).
class DeviceEnrollRoutes {
  DeviceEnrollRoutes(this._post, {required this.grant});
  final DevicePost _post;
  final String grant;

  Future<({int status, Map<String, dynamic>? body})> _send(
    String path,
    Map<String, dynamic> body,
  ) {
    if (!deviceKeyRequestAllowed(path, body)) {
      throw StateError('Device-key request not allowed');
    }
    return _post(path, body);
  }

  EnrollmentServer get enrollment =>
      EnrollmentServer(begin: _begin, finish: _finish);

  Future<EnrollChallenge?> _begin(Map<String, String> jwk) async {
    final r = await _send('/v1/manage/device-key/enroll-begin', {
      'publicJwk': {
        'kty': jwk['kty'],
        'crv': jwk['crv'],
        'x': jwk['x'],
        'y': jwk['y'],
      },
      'grant': grant,
    });
    if (r.status == 200) {
      final c = parseDeviceChallenge(r.body, 'enroll');
      if (c == null) throw const FormatException('begin body');
      return c;
    }
    if (r.status == 409) {
      throw r.body?['error'] == 'method_exists'
          ? const EnrollBeginMethodExists()
          : const EnrollBeginOpaque();
    }
    if (r.status == 429 || r.status >= 500) throw const EnrollBeginTransient();
    return null;
  }

  Future<EnrollFinishResponse> _finish(
    EnrollChallenge c,
    Uint8List signature,
  ) async {
    final r = await _send('/v1/manage/device-key/enroll-finish', {
      'grant': grant,
      'token': c.token,
      'signature': b64uNoPad(signature),
    });
    if (r.status == 200) {
      final b = r.body;
      final id = b?['keyId'];
      if (b != null &&
          b['status'] == 'enrolled' &&
          id is String &&
          id.isNotEmpty) {
        return EnrollFinishResponse(200, keyId: id);
      }
    }
    return EnrollFinishResponse(r.status);
  }
}

/// Read-only reconcile and adopt route clients (owner android session).
class DeviceStatusRoutes {
  DeviceStatusRoutes(this._post);
  final DevicePost _post;

  Future<({int status, Map<String, dynamic>? body})> _send(
    String path,
    Map<String, dynamic> body,
  ) {
    if (!deviceKeyRequestAllowed(path, body)) {
      throw StateError('Device-key request not allowed');
    }
    return _post(path, body);
  }

  /// Null for anything but a well-formed 200: never read as 'absent'.
  Future<({ServerKeyStatus status, String? keyId})?> status(
    String digest,
  ) async {
    final r = await _send('/v1/manage/device-key/enroll-status', {
      'digest': digest,
    });
    if (r.status != 200) return null;
    final b = r.body;
    switch (b?['status']) {
      case 'enrolled':
        final id = b?['keyId'];
        return id is String && id.isNotEmpty
            ? (status: ServerKeyStatus.enrolled, keyId: id)
            : null;
      case 'absent':
        return (status: ServerKeyStatus.absent, keyId: null);
      case 'revoked':
        return (status: ServerKeyStatus.revoked, keyId: null);
    }
    return null;
  }

  Future<EnrollChallenge?> adoptBegin(String digest) async {
    final r = await _send('/v1/manage/device-key/adopt-begin', {
      'digest': digest,
    });
    return r.status == 200 ? parseDeviceChallenge(r.body, 'step-up') : null;
  }

  /// Typed result: only {status:'enrolled', keyId} counts.
  Future<String?> adoptFinish(
    String digest,
    String token,
    Uint8List signature,
  ) async {
    final r = await _send('/v1/manage/device-key/adopt-finish', {
      'digest': digest,
      'token': token,
      'signature': b64uNoPad(signature),
    });
    final b = r.body;
    final id = b?['keyId'];
    return r.status == 200 &&
            b?['status'] == 'enrolled' &&
            id is String &&
            id.isNotEmpty
        ? id
        : null;
  }
}
