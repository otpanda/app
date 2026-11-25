import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';

/// Dart side of the OS-gated enrolled-device key (tool/android-recovery). Pure
/// contract, error and sequencing logic. It never signs by itself, never
/// deletes a key, and nothing here is wired into the app or the server yet.
/// Authoritative message: deviceProofMessage() in the API's
/// src/device-key-proof.js and tool/android-recovery/fixtures.

const deviceProofDomain = 'otpanda-device-proof-v1';
const deviceProofPurposes = {'enroll', 'step-up', 'recover-access'};
const minDeviceProofSdk = 30;

final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _b64u43 = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _hex64 = RegExp(r'^[a-f0-9]{64}$');
const _maxSafe = 9007199254740991;

/// The exact bytes the key signs: a compact JSON array, UTF-8.
Uint8List deviceProofMessage({
  required String purpose,
  required String ownerId,
  required String keyId,
  required int generation,
  required String challenge,
  required String actionDigest,
  required int expiresAt,
}) {
  if (!deviceProofPurposes.contains(purpose) ||
      !_id.hasMatch(ownerId) ||
      !_id.hasMatch(keyId) ||
      generation < 0 ||
      generation > _maxSafe ||
      !_b64u43.hasMatch(challenge) ||
      !_hex64.hasMatch(actionDigest) ||
      expiresAt < 0 ||
      expiresAt > _maxSafe) {
    throw const FormatException('invalid device proof fields');
  }
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        deviceProofDomain,
        purpose,
        ownerId,
        keyId,
        generation,
        challenge,
        actionDigest,
        expiresAt,
      ]),
    ),
  );
}

String _b64url(List<int> b) => base64Url.encode(b).replaceAll('=', '');

/// P-256 SubjectPublicKeyInfo (91 bytes, uncompressed point) to the exact
/// {kty, crv, x, y} JWK the server accepts. Anything else is refused.
Map<String, String> spkiToJwk(Uint8List spki) {
  const prefix = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00, 0x04,
  ];
  if (spki.length != prefix.length + 64) {
    throw const FormatException('not a P-256 SPKI');
  }
  for (var i = 0; i < prefix.length; i++) {
    if (spki[i] != prefix[i]) throw const FormatException('not a P-256 SPKI');
  }
  return {
    'kty': 'EC',
    'crv': 'P-256',
    'x': _b64url(spki.sublist(prefix.length, prefix.length + 32)),
    'y': _b64url(spki.sublist(prefix.length + 32)),
  };
}

enum DeviceProofAvailability {
  /// Ready: Android 11+ and a secure lock screen or enrolled strong biometric.
  available,
  unsupportedOs,
  noSecureLock,

  /// Biometric hardware busy or awaiting a security update. Retry later.
  temporarilyUnavailable,

  /// The host could not tell. Never treated as available.
  unknown,
}

enum DeviceProofFailureKind {
  cancelled,
  lockedOut,
  noSecureLock,
  temporarilyUnavailable,
  unsupportedOs,

  /// The key exists but the OS invalidated it (lock removed or reset). The
  /// server key stays active until another method revokes it.
  keyInvalidated,
  keyMissing,
  expired,
  failed,
}

class DeviceProofFailure implements Exception {
  const DeviceProofFailure(this.kind);
  final DeviceProofFailureKind kind;
  @override
  String toString() => 'DeviceProofFailure(${kind.name})';
}

/// The eight fields of one proof. The host rebuilds the message from them and
/// refuses to sign if its bytes differ from [message].
class DeviceProofFields {
  const DeviceProofFields({
    required this.purpose,
    required this.ownerId,
    required this.keyId,
    required this.generation,
    required this.challenge,
    required this.actionDigest,
    required this.expiresAt,
  });
  final String purpose, ownerId, keyId, challenge, actionDigest;
  final int generation, expiresAt;

  Uint8List get message => deviceProofMessage(
    purpose: purpose,
    ownerId: ownerId,
    keyId: keyId,
    generation: generation,
    challenge: challenge,
    actionDigest: actionDigest,
    expiresAt: expiresAt,
  );
  Map<String, Object> get args => {
    'purpose': purpose,
    'ownerId': ownerId,
    'keyId': keyId,
    'generation': generation,
    'challenge': challenge,
    'actionDigest': actionDigest,
    'expiresAt': expiresAt,
    'message': message,
  };
}

/// Canonical key text: JSON {kty,crv,x,y} in that order (server keyText).
String keyText(Map<String, String> jwk) => jsonEncode({
  'kty': jwk['kty'],
  'crv': jwk['crv'],
  'x': jwk['x'],
  'y': jwk['y'],
});

String _sha(String t) => crypto.sha256.convert(utf8.encode(t)).toString();

/// SHA-256 hex of [keyText], the server's key digest.
String publicKeyDigest(Map<String, String> jwk) => _sha(keyText(jwk));

/// The action digest the server must issue for an enroll challenge:
/// hashText(['enroll-device-key-v1', keyText]).
String deviceEnrollmentAction(Map<String, String> jwk) =>
    _sha(jsonEncode(['enroll-device-key-v1', keyText(jwk)]));

/// A challenge must expire in the future and within this window.
const maxChallengeLifetimeMs = 150000;

/// What a platform host implements. The host owns the Keystore and the OS
/// prompt; it never deletes or replaces a key on its own.
abstract interface class DeviceProofSource {
  Future<DeviceProofAvailability> availability();

  /// True when this device has the enrolled key (says nothing about the server).
  Future<bool> hasKey();

  /// The existing public SPKI, or null when no key exists. Read-only: never
  /// creates a key and shows no prompt.
  Future<Uint8List?> publicKeyOrNull();

  /// Creates the key, or returns the existing one if its policy matches.
  /// Returns the public SPKI. No prompt is shown.
  Future<Uint8List> createKeyForEnrollment();

  /// OS-verified signature (fixed 64-byte r||s) over [message].
  /// [displayText] is the readable action text for step-up prompts. The host
  /// refuses step-up while it is disabled.
  Future<Uint8List> sign(DeviceProofFields fields, {String? displayText});
}

/// Maps a platform error code to a stable failure. Unknown codes are 'failed'.
DeviceProofFailure failureFromCode(String? code) => DeviceProofFailure(
  switch (code) {
    'cancelled' => DeviceProofFailureKind.cancelled,
    'locked_out' => DeviceProofFailureKind.lockedOut,
    'no_secure_lock' => DeviceProofFailureKind.noSecureLock,
    'temporarily_unavailable' => DeviceProofFailureKind.temporarilyUnavailable,
    'unsupported_os' => DeviceProofFailureKind.unsupportedOs,
    'key_invalidated' => DeviceProofFailureKind.keyInvalidated,
    'key_missing' => DeviceProofFailureKind.keyMissing,
    'expired' => DeviceProofFailureKind.expired,
    _ => DeviceProofFailureKind.failed,
  },
);

/// Method-channel client. The host side (Kotlin) is not installed yet.
class ChannelDeviceProofSource implements DeviceProofSource {
  ChannelDeviceProofSource([MethodChannel? channel])
    : _c = channel ?? const MethodChannel('app.otpanda/device-proof');
  final MethodChannel _c;

  Future<T> _run<T>(Future<T?> Function() f) async {
    try {
      final v = await f();
      if (v == null) {
        throw const DeviceProofFailure(DeviceProofFailureKind.failed);
      }
      return v;
    } on PlatformException catch (e) {
      throw failureFromCode(e.code);
    } on MissingPluginException {
      throw const DeviceProofFailure(DeviceProofFailureKind.unsupportedOs);
    }
  }

  @override
  Future<DeviceProofAvailability> availability() async {
    try {
      final v = await _c.invokeMethod<String>('availability');
      return switch (v) {
        'available' => DeviceProofAvailability.available,
        'unsupported_os' => DeviceProofAvailability.unsupportedOs,
        'no_secure_lock' => DeviceProofAvailability.noSecureLock,
        'temporarily_unavailable' =>
          DeviceProofAvailability.temporarilyUnavailable,
        _ => DeviceProofAvailability.unknown,
      };
    } on MissingPluginException {
      return DeviceProofAvailability.unsupportedOs;
    } catch (_) {
      return DeviceProofAvailability.unknown;
    }
  }

  @override
  Future<Uint8List?> publicKeyOrNull() async {
    try {
      final v = await _c.invokeMethod<String>('publicKey');
      return v == null ? null : base64.decode(v);
    } on PlatformException catch (e) {
      throw failureFromCode(e.code);
    } on MissingPluginException {
      throw const DeviceProofFailure(DeviceProofFailureKind.unsupportedOs);
    } on FormatException {
      throw const DeviceProofFailure(DeviceProofFailureKind.failed);
    }
  }

  @override
  Future<bool> hasKey() => _run(() => _c.invokeMethod<bool>('hasKey'));

  @override
  Future<Uint8List> createKeyForEnrollment() =>
      _run(() => _c.invokeMethod<Uint8List>('createKeyForEnrollment'));

  @override
  Future<Uint8List> sign(DeviceProofFields fields, {String? displayText}) =>
      _run(
        () => _c.invokeMethod<Uint8List>('sign', {
          ...fields.args,
          if (displayText != null) 'displayText': displayText,
        }),
      );

  /// Writes the local record, only after the server returned a typed
  /// confirmation for exactly this key. Never replaces a different record.
  Future<void> saveConfirmed(String ownerId, String keyId) => _run(
    () => _c
        .invokeMethod<bool>('saveConfirmed', {
          'ownerId': ownerId,
          'keyId': keyId,
        })
        .then((v) => v == true ? true : null),
  );
}

/// Outcome of one enrollment attempt.
enum EnrollmentOutcome {
  /// The server confirmed this key.
  enrolled,

  /// The server said another method already exists: the first-method bootstrap
  /// is closed. The local key is NOT deleted here; a separate reconciliation
  /// decides, after the server proves it is not enrolled.
  methodExists,

  /// The server refused for another reason (rate limit, session, bad proof).
  rejected,

  /// The request may or may not have landed (timeout, network, lost
  /// response). The key is kept and the state is unknown, never cleaned up.
  unknown,

  /// The server answered begin with 429 or 5xx. No signature was made, the key
  /// is kept, and the same attempt may simply be repeated later.
  retryLater,

  /// Nothing was created: unsupported OS, no secure lock, cancelled, or the
  /// failure came before a key existed.
  notStarted,
}

/// Typed finish response. [keyId] is set only from a parsed 200 body.
class EnrollFinishResponse {
  const EnrollFinishResponse(this.status, {this.keyId});
  final int status;
  final String? keyId;
}

/// The server calls. [begin] returns the challenge, or null on a refusal.
/// [finish] returns the typed response, or throws when the response is lost.
class EnrollmentServer {
  const EnrollmentServer({required this.begin, required this.finish});
  final Future<EnrollChallenge?> Function(Map<String, String> jwk) begin;
  final Future<EnrollFinishResponse> Function(
    EnrollChallenge c,
    Uint8List signature,
  )
  finish;
}

/// Thrown by [EnrollmentServer.begin] for a definitive 429 or 5xx answer.
class EnrollBeginTransient implements Exception {
  const EnrollBeginTransient();
}

/// Thrown by [EnrollmentServer.begin] for 409 {"error":"method_exists"}: a
/// passkey or another key already exists. Show the existing-method sign-in.
class EnrollBeginMethodExists implements Exception {
  const EnrollBeginMethodExists();
}

/// Thrown by begin for the opaque 409 {"error":"unavailable"}: never setup;
/// reconcile through enroll-status.
class EnrollBeginOpaque implements Exception {
  const EnrollBeginOpaque();
}

class EnrollChallenge {
  const EnrollChallenge({
    required this.token,
    required this.ownerId,
    required this.keyId,
    required this.generation,
    required this.challenge,
    required this.actionDigest,
    required this.expiresAt,
    this.purpose = 'enroll',
  });
  final String token, ownerId, keyId, challenge, actionDigest, purpose;
  final int generation, expiresAt;
}

/// An already-signed finish whose response was lost. Retried byte-for-byte
/// with no new OS prompt, only while the server still keeps its receipt.
/// Memory only: after a restart the possession-based status check applies.
class PendingFinish {
  const PendingFinish(
    this.challenge,
    this.signature,
    this.retryUntil,
    this.publicKeyDigest,
  );
  final String publicKeyDigest;
  final EnrollChallenge challenge;
  final Uint8List signature;
  final int retryUntil;
}

const enrollReceiptWindowMs = 600000;

class EnrollmentResult {
  const EnrollmentResult(
    this.outcome, {
    this.failure,
    this.keyId,
    this.pending,
    this.publicKeyDigest,
    this.beginExpiresAt,
  });
  final EnrollmentOutcome outcome;
  final DeviceProofFailure? failure;

  /// Only on enrolled: the server-confirmed key id.
  final String? keyId;

  /// Only on unknown after a signature: the exact finish to repeat.
  final PendingFinish? pending;

  /// Set once a key exists, so a later status check can name it.
  final String? publicKeyDigest;

  /// The begin challenge's expiry, needed to judge 'absent' later.
  final int? beginExpiresAt;
}

EnrollmentResult _judge(
  EnrollChallenge c,
  EnrollFinishResponse r,
  String digest,
  PendingFinish pending,
) {
  final ok = r.status == 200;
  if (ok && r.keyId != null && _id.hasMatch(r.keyId!) && r.keyId == c.keyId) {
    return EnrollmentResult(
      EnrollmentOutcome.enrolled,
      keyId: r.keyId,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  // A 2xx without a matching keyId (including 201/204 or a different key)
  // proves nothing and may have had an effect: unknown, never enrolled.
  if (r.status >= 200 && r.status < 300 || r.status >= 500) {
    return EnrollmentResult(
      EnrollmentOutcome.unknown,
      pending: pending,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  // Finish 409 is always opaque in the v8 wire contract ('unavailable'): not
  // confirmed, reconcile through enroll-status. method_exists exists on begin only.
  // 429 on finish: the same signed finish may be repeated (no second OS
  // prompt) after the retry floor, inside the receipt window.
  if (r.status == 409 || r.status == 429) {
    return EnrollmentResult(
      EnrollmentOutcome.unknown,
      pending: pending,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  return EnrollmentResult(
    EnrollmentOutcome.rejected,
    publicKeyDigest: digest,
    beginExpiresAt: c.expiresAt,
  );
}

/// Runs one first-enrollment attempt in order: availability, key (no prompt),
/// server begin, OS-verified signature, server finish. It never deletes a key.
/// Enrolled means a 200 with the challenge's own keyId and nothing less.
Future<EnrollmentResult> enrollDevice(
  DeviceProofSource source,
  EnrollmentServer server, {
  required String expectedOwnerId,
  required String sessionDeviceId,
  int? expectedGeneration,
  String? expectedKeyId,
  Future<void> Function(String keyId)? onEnrolled,
  PendingEnrollStore? store,
  int Function()? now,
}) async {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  final a = await source.availability();
  if (a != DeviceProofAvailability.available) {
    return EnrollmentResult(
      EnrollmentOutcome.notStarted,
      failure: DeviceProofFailure(switch (a) {
        DeviceProofAvailability.noSecureLock =>
          DeviceProofFailureKind.noSecureLock,
        DeviceProofAvailability.unsupportedOs =>
          DeviceProofFailureKind.unsupportedOs,
        DeviceProofAvailability.temporarilyUnavailable =>
          DeviceProofFailureKind.temporarilyUnavailable,
        _ => DeviceProofFailureKind.failed,
      }),
    );
  }
  Map<String, String> jwk;
  try {
    jwk = spkiToJwk(await source.createKeyForEnrollment());
  } on DeviceProofFailure catch (e) {
    return EnrollmentResult(EnrollmentOutcome.notStarted, failure: e);
  } on FormatException {
    return const EnrollmentResult(
      EnrollmentOutcome.notStarted,
      failure: DeviceProofFailure(DeviceProofFailureKind.failed),
    );
  }
  // From here a key may exist on the device. No branch below removes it.
  final digest = publicKeyDigest(jwk);
  final start = clock();
  try {
    await store?.write(
      PendingRecord(
        state: PendingState.begun,
        digest: digest,
        requestStartMs: start,
        ownerId: expectedOwnerId,
        sessionDeviceId: sessionDeviceId,
      ),
    );
  } catch (_) {
    // Cannot guarantee crash recovery: send nothing.
    return EnrollmentResult(
      EnrollmentOutcome.notStarted,
      failure: const DeviceProofFailure(DeviceProofFailureKind.failed),
      publicKeyDigest: digest,
    );
  }
  EnrollChallenge? c;
  try {
    c = await server.begin(jwk);
  } on EnrollBeginMethodExists {
    return EnrollmentResult(
      EnrollmentOutcome.methodExists,
      publicKeyDigest: digest,
    );
  } on EnrollBeginOpaque {
    return EnrollmentResult(EnrollmentOutcome.unknown, publicKeyDigest: digest);
  } on EnrollBeginTransient {
    return EnrollmentResult(
      EnrollmentOutcome.retryLater,
      publicKeyDigest: digest,
    );
  } catch (_) {
    return EnrollmentResult(EnrollmentOutcome.unknown, publicKeyDigest: digest);
  }
  if (c == null) {
    return EnrollmentResult(
      EnrollmentOutcome.rejected,
      publicKeyDigest: digest,
    );
  }
  final DeviceProofFields fields;
  try {
    fields = DeviceProofFields(
      purpose: 'enroll',
      ownerId: c.ownerId,
      keyId: c.keyId,
      generation: c.generation,
      challenge: c.challenge,
      actionDigest: c.actionDigest,
      expiresAt: c.expiresAt,
    );
    fields.message;
  } on FormatException {
    return EnrollmentResult(
      EnrollmentOutcome.rejected,
      publicKeyDigest: digest,
    );
  }
  final t = clock();
  if (c.expiresAt <= t) {
    return EnrollmentResult(
      EnrollmentOutcome.rejected,
      failure: const DeviceProofFailure(DeviceProofFailureKind.expired),
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  // Validate everything the OS prompt will vouch for BEFORE signing: purpose
  // enroll is fixed by this flow; the digest must be exactly our own key's
  // enrollment action, the owner the stored session's, the lifetime sane.
  if (c.purpose != 'enroll' ||
      (expectedKeyId != null && c.keyId != expectedKeyId) ||
      c.actionDigest != deviceEnrollmentAction(jwk) ||
      c.ownerId != expectedOwnerId ||
      c.keyId.isEmpty ||
      (expectedGeneration != null && c.generation != expectedGeneration) ||
      c.generation < 0 ||
      c.expiresAt > t + maxChallengeLifetimeMs) {
    return EnrollmentResult(
      EnrollmentOutcome.rejected,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  try {
    await store?.write(
      PendingRecord(
        state: PendingState.begun,
        digest: digest,
        requestStartMs: start,
        ownerId: expectedOwnerId,
        sessionDeviceId: sessionDeviceId,
        keyId: c.keyId,
        expiresAtMs: c.expiresAt,
      ),
    );
  } catch (_) {
    return EnrollmentResult(
      EnrollmentOutcome.notStarted,
      failure: const DeviceProofFailure(DeviceProofFailureKind.failed),
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  Uint8List sig;
  try {
    sig = await source.sign(fields);
  } on DeviceProofFailure catch (e) {
    // Nothing was sent, so the server never saw a finish for this challenge.
    return EnrollmentResult(
      EnrollmentOutcome.rejected,
      failure: e,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  if (sig.length != 64) {
    return EnrollmentResult(
      EnrollmentOutcome.rejected,
      failure: const DeviceProofFailure(DeviceProofFailureKind.failed),
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  final pending = PendingFinish(
    c,
    sig,
    clock() + enrollReceiptWindowMs,
    digest,
  );
  try {
    await store?.write(
      PendingRecord(
        state: PendingState.finishSent,
        digest: digest,
        requestStartMs: start,
        ownerId: expectedOwnerId,
        sessionDeviceId: sessionDeviceId,
        sentAtMs: clock(),
        keyId: c.keyId,
        expiresAtMs: c.expiresAt,
        token: c.token,
        signature: sig,
      ),
    );
  } catch (_) {
    // Signed but not durable: do not send, the signature stays in memory only.
    return EnrollmentResult(
      EnrollmentOutcome.unknown,
      pending: pending,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
  try {
    final res = _judge(c, await server.finish(c, sig), digest, pending);
    if (res.outcome == EnrollmentOutcome.enrolled) {
      // Record the confirmation natively first; keep the pending record if
      // that fails so recovery can finish it.
      await onEnrolled?.call(res.keyId!);
      await store?.clear();
    }
    return res;
  } catch (_) {
    return EnrollmentResult(
      EnrollmentOutcome.unknown,
      pending: pending,
      publicKeyDigest: digest,
      beginExpiresAt: c.expiresAt,
    );
  }
}

/// Repeats the identical finish after a lost response: same token, same
/// signature bytes, no OS prompt. Past the receipt window it refuses, and the
/// caller reconciles by possession instead.
Future<EnrollmentResult> retryEnrollFinish(
  PendingFinish p,
  EnrollmentServer server, {
  int Function()? now,
}) async {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  if (clock() >= p.retryUntil) {
    return EnrollmentResult(
      EnrollmentOutcome.unknown,
      publicKeyDigest: p.publicKeyDigest,
    );
  }
  try {
    return _judge(
      p.challenge,
      await server.finish(p.challenge, p.signature),
      p.publicKeyDigest,
      p,
    );
  } catch (_) {
    return EnrollmentResult(
      EnrollmentOutcome.unknown,
      pending: p,
      publicKeyDigest: p.publicKeyDigest,
    );
  }
}

enum ServerKeyStatus { enrolled, absent, revoked }

enum ReconcileAction {
  /// Server has the key: adopt it with one OS-verified step-up. Needs the
  /// step-up signer, which stays disabled until the canonical contract lands.
  adopt,

  /// Server says absent but the begin challenge could still be finishing.
  waitForExpiry,

  /// Absent after expiry: keep the key and start a new Google grant.
  keepKeyAndRegrant,

  /// Revoked: a tombstone. The old key is never reused; create a new one.
  createNewKey,
}

/// The earliest moment 'absent' may be trusted: the full 120 s from the
/// request START (a lost begin may still have created a challenge), and never
/// before the challenge's own expiry when one was received.
int absentFloorMs(int requestStartMs, int? beginExpiresAt) {
  final byStart = requestStartMs + 120000;
  return beginExpiresAt != null && beginExpiresAt > byStart
      ? beginExpiresAt
      : byStart;
}

/// Decides what follows a status reply. No branch deletes anything: even
/// 'revoked' leaves the old key in place until a separate, explicit step.
ReconcileAction decideReconcile(
  ServerKeyStatus status, {
  required int requestStartMs,
  int? beginExpiresAt,
  required int now,
}) => switch (status) {
  ServerKeyStatus.enrolled => ReconcileAction.adopt,
  ServerKeyStatus.revoked => ReconcileAction.createNewKey,
  ServerKeyStatus.absent =>
    now > absentFloorMs(requestStartMs, beginExpiresAt)
        ? ReconcileAction.keepKeyAndRegrant
        : ReconcileAction.waitForExpiry,
};

/// Persisted progress of one enrollment (noBackup, survives process death).
/// Nothing here is ever deleted on an unknown outcome.
enum PendingState { keyCreated, begun, finishSent }

class PendingRecord {
  const PendingRecord({
    required this.state,
    required this.digest,
    required this.requestStartMs,
    required this.ownerId,
    required this.sessionDeviceId,
    this.keyId,
    this.expiresAtMs,
    this.sentAtMs,
    this.token,
    this.signature,
  });
  final PendingState state;
  final String digest;
  final int requestStartMs;

  /// The account and session this attempt belongs to. A record for another
  /// owner is never applied (and never deleted) after an account switch.
  final String ownerId, sessionDeviceId;
  final int? sentAtMs;
  final String? keyId, token;
  final int? expiresAtMs;
  final Uint8List? signature;

  String encode() => jsonEncode({
    'v': 1,
    'state': state.name,
    'digest': digest,
    'start': requestStartMs,
    'owner': ownerId,
    'device': sessionDeviceId,
    if (sentAtMs != null) 'sent': sentAtMs,
    if (keyId != null) 'keyId': keyId,
    if (expiresAtMs != null) 'exp': expiresAtMs,
    if (token != null) 'token': token,
    if (signature != null) 'sig': base64Url.encode(signature!),
  });

  /// Null for anything unreadable: the caller then reconciles by possession.
  static PendingRecord? decode(String? text) {
    if (text == null) return null;
    try {
      final m = jsonDecode(text);
      if (m is! Map || m['v'] != 1) return null;
      final st = PendingState.values.where((e) => e.name == m['state']);
      final d = m['digest'], t = m['start'];
      final o = m['owner'], dv = m['device'];
      if (st.isEmpty ||
          d is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(d) ||
          t is! int ||
          o is! String ||
          o.isEmpty ||
          dv is! String ||
          dv.isEmpty) {
        return null;
      }
      final sig = m['sig'];
      final kid = m['keyId'],
          exp = m['exp'],
          tok = m['token'],
          sent = m['sent'];
      if ((kid != null && (kid is! String || kid.isEmpty)) ||
          (exp != null && exp is! int) ||
          (tok != null && tok is! String) ||
          (sent != null && sent is! int)) {
        return null;
      }
      Uint8List? sigBytes;
      if (sig != null) {
        if (sig is! String) return null;
        try {
          sigBytes = Uint8List.fromList(base64Url.decode(sig));
        } on FormatException {
          return null;
        }
      }
      // State-specific shape: finishSent must carry the full identical finish.
      if (st.first == PendingState.finishSent &&
          (kid == null ||
              exp == null ||
              tok is! String ||
              !RegExp(r'^otpda_[A-Za-z0-9_-]{55}$').hasMatch(tok) ||
              sent == null ||
              sigBytes == null ||
              sigBytes.length != 64)) {
        return null;
      }
      if (st.first != PendingState.finishSent && (tok != null || sig != null)) {
        return null;
      }
      return PendingRecord(
        state: st.first,
        digest: d,
        requestStartMs: t,
        ownerId: o,
        sessionDeviceId: dv,
        sentAtMs: sent as int?,
        signature: sigBytes,
        keyId: kid as String?,
        expiresAtMs: exp as int?,
        token: tok as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

class PendingRead {
  const PendingRead._(this.record, this.unreadable);
  const PendingRead.none() : this._(null, false);
  const PendingRead.unreadable() : this._(null, true);
  const PendingRead.record(PendingRecord r) : this._(r, false);
  final PendingRecord? record;
  final bool unreadable;
}

/// Durable store for [PendingRecord]. A write failure before a network step
/// stops that step, so a crash can always be reconciled.
abstract interface class PendingEnrollStore {
  /// [PendingRead.unreadable] means bytes exist but are not a valid record:
  /// never treated as empty.
  Future<PendingRead> read();
  Future<void> write(PendingRecord record);

  /// Only after a typed, keyId-matched server confirmation.
  Future<void> clear();
}

class ChannelPendingStore implements PendingEnrollStore {
  ChannelPendingStore([MethodChannel? channel])
    : _c = channel ?? const MethodChannel('app.otpanda/device-proof');
  final MethodChannel _c;
  @override
  Future<PendingRead> read() async {
    String? raw;
    try {
      raw = await _c.invokeMethod<String>('pendingRead');
    } on PlatformException {
      // Oversize or unreadable file: unknown, never 'none' (no overwrite).
      return const PendingRead.unreadable();
    }
    if (raw == null) return const PendingRead.none();
    final r = PendingRecord.decode(raw);
    return r == null ? const PendingRead.unreadable() : PendingRead.record(r);
  }

  @override
  Future<void> write(PendingRecord record) async {
    await _c.invokeMethod<bool>('pendingWrite', {'record': record.encode()});
  }

  @override
  Future<void> clear() async {
    await _c.invokeMethod<bool>('pendingClear');
  }
}
