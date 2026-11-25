import 'dart:convert';
import 'dart:typed_data';

import 'native_action_proof.dart';
import 'native_device_proof.dart';
import 'native_device_routes.dart';

/// An approval request may live at most this long (v8: 600 s).
const maxApprovalLifetimeMs = 600000;

final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _fingerprintShape = RegExp(r'^[0-9a-f]{4}(-[0-9a-f]{4}){3}$');

/// First 16 hex of the key digest in groups of four (v8 5.3). Shown on both
/// phones; the new phone computes it locally and requires the server to match.
String fingerprintOf(String keyDigest) {
  final h = keyDigest.substring(0, 16);
  return [for (var i = 0; i < 16; i += 4) h.substring(i, i + 4)].join('-');
}

class ApprovalRow {
  const ApprovalRow({
    required this.changeId,
    required this.kind,
    required this.target,
    required this.requesterLabel,
    required this.requesterKind,
    required this.requestedAt,
    required this.expiresAt,
  });

  /// Server-derived 'web' or 'android'; display only, never in a digest.
  final String requesterKind;

  /// When the REQUEST was created (epoch ms), not the requester's session age.
  final int requestedAt;
  final String changeId, kind;
  final String? target, requesterLabel;
  final int expiresAt;
}

class ApprovalStatus {
  const ApprovalStatus(this.ownerId, this.generation, this.pending);
  final String ownerId;
  final int generation;
  final List<ApprovalRow> pending;
}

/// Strict parse of approval/status. Exactly the allowed fields, at most 8
/// rows; anything else is null (nothing is shown or signed).
ApprovalStatus? parseApprovalStatus(Map<String, dynamic>? b) {
  if (b == null || b.length != 3) return null;
  final o = b['ownerId'], g = b['generation'], p = b['pending'];
  if (o is! String || o.isEmpty || g is! int || g < 0 || p is! List)
    return null;
  if (p.length > 8) return null;
  final rows = <ApprovalRow>[];
  for (final r in p) {
    if (r is! Map || r.length != 7) return null;
    final id = r['changeId'], kind = r['kind'], t = r['target'];
    final label = r['requesterLabel'], ex = r['expiresAt'];
    final rk = r['requesterKind'], ra = r['requestedAt'];
    if (id is! String || id.isEmpty || id.length > 128) return null;
    if (kind != 'passkey-add' && kind != 'device-key-add') return null;
    if (kind == 'device-key-add'
        ? (t is! String || !_hex64.hasMatch(t))
        : t != null) {
      return null;
    }
    if (label != null && (label is! String || label.length > 64)) return null;
    if (ex is! int) return null;
    if (rk != 'web' && rk != 'android') return null;
    // Created before it expires, and the server window is at most 600 s.
    if (ra is! int || ra <= 0 || ra > ex || ex - ra > maxApprovalLifetimeMs) {
      return null;
    }
    if (kind == 'device-key-add' && rk != 'android') return null;
    rows.add(
      ApprovalRow(
        changeId: id,
        kind: kind as String,
        target: t as String?,
        requesterLabel: label as String?,
        requesterKind: rk as String,
        requestedAt: ra,
        expiresAt: ex,
      ),
    );
  }
  return ApprovalStatus(o, g, rows);
}

/// Everything checked before the phone may ask for the OS gesture on an
/// approval. Returns the readable prompt, or null (no prompt, no signature).
String? validateApprovalChallenge({
  required ApprovalStatus status,
  required ApprovalRow row,
  required EnrollChallenge challenge,
  required String storedOwnerId,
  required String ownKeyId,
  required String accountEmail,
  required int nowMs,
}) {
  if (!status.pending.contains(row)) return null;
  if (status.ownerId != storedOwnerId ||
      challenge.ownerId != storedOwnerId ||
      challenge.generation != status.generation) {
    return null;
  }
  if (challenge.purpose != 'step-up' || challenge.keyId != ownKeyId) {
    return null;
  }
  if (challenge.expiresAt <= nowMs ||
      challenge.expiresAt > nowMs + maxProofLifetimeMs ||
      row.expiresAt <= nowMs ||
      row.expiresAt > nowMs + maxApprovalLifetimeMs) {
    return null;
  }
  final want = approvalActionDigest(
    changeId: row.changeId,
    kind: row.kind,
    target: row.target,
    ownerId: status.ownerId,
    generation: status.generation,
  );
  if (challenge.actionDigest != want) return null;
  final fp = row.target == null ? null : fingerprintOf(row.target!);
  return approvalPrompt(
    kind: row.kind,
    accountEmail: accountEmail,
    requesterLabel: row.requesterLabel,
    requesterKind: row.requesterKind,
    requestedAtMs: row.requestedAt,
    nowMs: nowMs,
    fingerprint: fp,
  );
}

/// Approver-side clients (an enrolled phone approving another method).
class ApprovalRoutes {
  ApprovalRoutes(this._post);
  final DevicePost _post;

  Future<({int status, Map<String, dynamic>? body})> _send(
    String path,
    Map<String, dynamic> body,
  ) {
    if (!deviceKeyRequestAllowed(path, body)) {
      throw StateError('Approval request not allowed');
    }
    return _post(path, body);
  }

  Future<ApprovalStatus?> status() async {
    final r = await _send('/v1/manage/approval/status', {});
    return r.status == 200 ? parseApprovalStatus(r.body) : null;
  }

  Future<EnrollChallenge?> approveBegin(String changeId, String keyId) async {
    final r = await _send('/v1/manage/approval/approve-begin', {
      'changeId': changeId,
      'keyId': keyId,
    });
    return r.status == 200 ? parseDeviceChallenge(r.body, 'step-up') : null;
  }

  /// True only for a typed 200 {status:'approved'}. Anything else is not
  /// confirmed (the caller re-reads status, never re-signs).
  Future<bool> approveFinish(
    String changeId,
    String token,
    Uint8List signature,
  ) async {
    final r = await _send('/v1/manage/approval/approve-finish', {
      'changeId': changeId,
      'token': token,
      'signature': b64uNoPad(signature),
    });
    return r.status == 200 && r.body?['status'] == 'approved';
  }
}

class AddRequestReply {
  const AddRequestReply(this.changeId, this.expiresAt, this.fingerprint);
  final String changeId, fingerprint;
  final int expiresAt;
}

/// New-phone-side clients (second phone, v8 5.3).
class AddDeviceRoutes {
  AddDeviceRoutes(this._post);
  final DevicePost _post;

  Future<({int status, Map<String, dynamic>? body})> _send(
    String path,
    Map<String, dynamic> body,
  ) {
    if (!deviceKeyRequestAllowed(path, body)) {
      throw StateError('Add-device request not allowed');
    }
    return _post(path, body);
  }

  /// Null unless a well-formed 200 whose fingerprint equals the LOCAL one.
  Future<AddRequestReply?> addRequest(Map<String, String> jwk) async {
    final r = await _send('/v1/manage/device-key/add-request', {
      'publicJwk': {
        'kty': jwk['kty'],
        'crv': jwk['crv'],
        'x': jwk['x'],
        'y': jwk['y'],
      },
    });
    final b = r.body;
    if (r.status != 200 || b == null || b.length != 3) return null;
    final id = b['changeId'], ex = b['expiresAt'], fp = b['fingerprint'];
    if (id is! String || id.isEmpty || ex is! int || fp is! String) return null;
    if (!_fingerprintShape.hasMatch(fp) ||
        fp != fingerprintOf(publicKeyDigest(jwk))) {
      return null;
    }
    return AddRequestReply(id, ex, fp);
  }

  /// Null until the approval exists (opaque 409) or on any malformed reply.
  Future<EnrollChallenge?> addBegin(String changeId) async {
    final r = await _send('/v1/manage/device-key/add-begin', {
      'changeId': changeId,
    });
    return r.status == 200 ? parseDeviceChallenge(r.body, 'enroll') : null;
  }

  Future<EnrollFinishResponse> addFinish(
    String changeId,
    EnrollChallenge c,
    Uint8List signature,
  ) async {
    final r = await _send('/v1/manage/device-key/add-finish', {
      'changeId': changeId,
      'token': c.token,
      'signature': b64uNoPad(signature),
    });
    final id = r.body?['keyId'];
    if (r.status == 200 &&
        r.body?['status'] == 'enrolled' &&
        id is String &&
        id.isNotEmpty) {
      return EnrollFinishResponse(200, keyId: id);
    }
    return EnrollFinishResponse(r.status);
  }
}

enum AddState {
  requested,
  begun,
  finishSent,

  /// The slot was unreadable: a persisted start (the stable absent-floor
  /// anchor) written before any status call. No change, key or bytes.
  recovering,
}

/// The second phone's persisted progress (v8 8.4). One record, replaced whole.
class AddPendingRecord {
  const AddPendingRecord({
    required this.state,
    required this.ownerId,
    required this.sessionDeviceId,
    required this.changeId,
    required this.digest,
    required this.requestStartMs,
    this.keyId,
    this.approvalExpiresAtMs,
    this.challengeExpiresAtMs,
    this.sentAtMs,
    this.token,
    this.signature,
  });
  final AddState state;
  final String ownerId, sessionDeviceId, changeId, digest;

  /// Server-assigned at add-begin: null while only requested.
  final String? keyId;
  final int requestStartMs;
  final int? approvalExpiresAtMs, challengeExpiresAtMs, sentAtMs;
  final String? token;
  final Uint8List? signature;

  String encode() => jsonEncode({
    'v': 1,
    'flow': 'add',
    'state': state.name,
    'owner': ownerId,
    'device': sessionDeviceId,
    'change': changeId,
    'digest': digest,
    if (keyId != null) 'keyId': keyId,
    'start': requestStartMs,
    if (approvalExpiresAtMs != null) 'aexp': approvalExpiresAtMs,
    if (challengeExpiresAtMs != null) 'cexp': challengeExpiresAtMs,
    if (sentAtMs != null) 'sent': sentAtMs,
    if (token != null) 'token': token,
    if (signature != null) 'sig': base64Url.encode(signature!),
  });

  static AddPendingRecord? decode(String? text) {
    if (text == null) return null;
    try {
      final m = jsonDecode(text);
      if (m is! Map || m['v'] != 1 || m['flow'] != 'add') return null;
      final st = AddState.values.where((e) => e.name == m['state']);
      final o = m['owner'], dv = m['device'], ch = m['change'];
      final d = m['digest'], k = m['keyId'], start = m['start'];
      if (st.isEmpty ||
          o is! String ||
          o.isEmpty ||
          dv is! String ||
          dv.isEmpty ||
          ch is! String ||
          ch.isEmpty ||
          d is! String ||
          !_hex64.hasMatch(d) ||
          (k != null && (k is! String || k.isEmpty)) ||
          start is! int) {
        return null;
      }
      int? opt(String key) {
        final v = m[key];
        if (v == null) return null;
        if (v is! int) throw const FormatException('int');
        return v;
      }

      final aexp = opt('aexp'), cexp = opt('cexp'), sent = opt('sent');
      final tok = m['token'], sig = m['sig'];
      Uint8List? sigBytes;
      if (sig != null) {
        if (sig is! String) return null;
        sigBytes = Uint8List.fromList(base64Url.decode(sig));
      }
      final fin = st.first == AddState.finishSent;
      if (fin) {
        if (tok is! String ||
            !RegExp(r'^otpda_[A-Za-z0-9_-]{55}$').hasMatch(tok) ||
            sigBytes == null ||
            sigBytes.length != 64 ||
            sent == null ||
            cexp == null) {
          return null;
        }
      } else if (tok != null || sig != null || sent != null) {
        return null;
      }
      if (st.first == AddState.requested && (aexp == null || k != null)) {
        return null;
      }
      if (st.first == AddState.recovering &&
          (k != null || aexp != null || cexp != null)) {
        return null;
      }
      if (st.first != AddState.requested &&
          st.first != AddState.recovering &&
          k == null) {
        return null;
      }
      return AddPendingRecord(
        state: st.first,
        ownerId: o,
        sessionDeviceId: dv,
        changeId: ch,
        digest: d,
        keyId: k as String?,
        requestStartMs: start,
        approvalExpiresAtMs: aexp,
        challengeExpiresAtMs: cexp,
        sentAtMs: sent,
        token: tok as String?,
        signature: sigBytes,
      );
    } catch (_) {
      return null;
    }
  }
}
