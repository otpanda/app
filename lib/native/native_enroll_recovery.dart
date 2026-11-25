import 'native_device_proof.dart';
import 'native_device_routes.dart';

enum RecoveryOutcome {
  /// Nothing stored. Fresh setup is allowed.
  nothing,

  /// A record for another account. Left untouched, never applied.
  foreignRecord,

  /// The identical stored finish succeeded (typed 200 + matching keyId).
  enrolled,

  /// The server holds this key. Adopting it needs one step-up signature, and
  /// that signer is disabled, so this stays pending.
  needsAdopt,

  /// Server says absent but the request-start/expiry floor has not passed.
  waiting,

  /// Absent after the floor: keep the key, get a new Google grant, same key.
  regrant,

  /// Server says revoked: a new key is only allowed through an authorized
  /// existing method.
  revokedNeedsMethod,

  /// Status could not be read or the key is not confirmable. State is kept.
  unknown,
}

class RecoveryResult {
  const RecoveryResult(this.outcome, {this.keyId, this.waitUntilMs});
  final RecoveryOutcome outcome;
  final String? keyId;
  final int? waitUntilMs;
}

/// Startup recovery after a crash or lost response. Order, from the stored
/// record only (never from memory):
///  1. no record: nothing (a record that exists but is unreadable is
///     replaced by a fresh valid begun record for the local public key, which
///     is read, never created, then reconciled by possession);
///  2. another owner's record: ignored and kept;
///  3. finishSent from THIS session within 10 minutes of the send: repeat the
///     identical bytes (no new prompt); a typed enrolled confirms;
///     The enroll grant is memory only: after process death [enrollRoutes] is
///     null, step 3 cannot run, and recovery goes to status / adopt. Nothing
///     may claim the finish was silently replayed.
///  4. otherwise ask enroll-status for the key digest and decide from the
///     request-start floor. Nothing is ever deleted except a confirmed enroll.
Future<RecoveryResult> recoverEnrollment({
  required PendingEnrollStore store,
  required DeviceProofSource source,
  required DeviceEnrollRoutes? enrollRoutes,
  required DeviceStatusRoutes statusRoutes,
  required String ownerId,
  required String sessionDeviceId,
  required Future<void> Function(String keyId) onEnrolled,
  int Function()? now,
}) async {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  final read = await store.read();
  String digest;
  int start;
  int? exp;
  PendingRecord? rec = read.record;
  if (rec == null && !read.unreadable) {
    return const RecoveryResult(RecoveryOutcome.nothing);
  }
  if (rec != null) {
    if (rec.ownerId != ownerId) {
      return const RecoveryResult(RecoveryOutcome.foreignRecord);
    }
    digest = rec.digest;
    start = rec.requestStartMs;
    exp = rec.expiresAtMs;
  } else {
    // Unreadable: read (never create) the local public key, then persist a
    // fresh VALID begun record (own owner, session, digest, start NOW) BEFORE
    // asking the server. A later run then keeps this start instead of
    // resetting the floor forever. A write failure leaves the state unknown.
    try {
      final spki = await source.publicKeyOrNull();
      if (spki == null) return const RecoveryResult(RecoveryOutcome.unknown);
      digest = publicKeyDigest(spkiToJwk(spki));
      start = clock();
      rec = PendingRecord(
        state: PendingState.begun,
        digest: digest,
        requestStartMs: start,
        ownerId: ownerId,
        sessionDeviceId: sessionDeviceId,
      );
      await store.write(rec);
    } catch (_) {
      return const RecoveryResult(RecoveryOutcome.unknown);
    }
  }
  if (rec.state == PendingState.finishSent &&
      rec.sessionDeviceId == sessionDeviceId &&
      enrollRoutes != null &&
      clock() - rec.sentAtMs! < enrollReceiptWindowMs &&
      clock() >= rec.sentAtMs!) {
    final c = EnrollChallenge(
      token: rec.token!,
      ownerId: rec.ownerId,
      keyId: rec.keyId!,
      generation: 0,
      challenge: '',
      actionDigest: '',
      expiresAt: rec.expiresAtMs!,
    );
    try {
      final res = await enrollRoutes.enrollment.finish(c, rec.signature!);
      if (res.status == 200 && res.keyId == rec.keyId) {
        await onEnrolled(res.keyId!);
        await store.clear();
        return RecoveryResult(RecoveryOutcome.enrolled, keyId: res.keyId);
      }
    } catch (_) {
      // Fall through to the possession check; the record stays.
    }
  }
  final st = await _status(statusRoutes, digest);
  if (st == null) return const RecoveryResult(RecoveryOutcome.unknown);
  switch (st.status) {
    case ServerKeyStatus.enrolled:
      return RecoveryResult(RecoveryOutcome.needsAdopt, keyId: st.keyId);
    case ServerKeyStatus.revoked:
      return const RecoveryResult(RecoveryOutcome.revokedNeedsMethod);
    case ServerKeyStatus.absent:
      final floor = absentFloorMs(start, exp);
      return clock() > floor
          ? const RecoveryResult(RecoveryOutcome.regrant)
          : RecoveryResult(RecoveryOutcome.waiting, waitUntilMs: floor);
  }
}

Future<({ServerKeyStatus status, String? keyId})?> _status(
  DeviceStatusRoutes r,
  String digest,
) async {
  try {
    return await r.status(digest);
  } catch (_) {
    return null;
  }
}
