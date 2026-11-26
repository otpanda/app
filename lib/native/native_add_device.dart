import 'package:flutter/services.dart';

import 'native_device_routes.dart';
import 'native_approval_routes.dart';
import 'native_device_proof.dart';

class AddPendingRead {
  const AddPendingRead._(this.record, this.unreadable);
  const AddPendingRead.none() : this._(null, false);
  const AddPendingRead.unreadable() : this._(null, true);
  const AddPendingRead.record(AddPendingRecord r) : this._(r, false);
  final AddPendingRecord? record;
  final bool unreadable;
}

/// One record, replaced whole (second slot in the noBackup store).
abstract interface class AddPendingStore {
  Future<AddPendingRead> read();
  Future<void> write(AddPendingRecord r);
  Future<void> clear();
}

class ChannelAddPendingStore implements AddPendingStore {
  ChannelAddPendingStore([MethodChannel? channel])
    : _c = channel ?? const MethodChannel('app.otpanda/device-proof');
  final MethodChannel _c;
  @override
  Future<AddPendingRead> read() async {
    String? raw;
    try {
      raw = await _c.invokeMethod<String>('pendingRead', {'slot': 'add'});
    } on PlatformException {
      return const AddPendingRead.unreadable();
    }
    if (raw == null) return const AddPendingRead.none();
    final r = AddPendingRecord.decode(raw);
    return r == null
        ? const AddPendingRead.unreadable()
        : AddPendingRead.record(r);
  }

  @override
  Future<void> write(AddPendingRecord r) async {
    await _c.invokeMethod<bool>('pendingWrite', {
      'slot': 'add',
      'record': r.encode(),
    });
  }

  @override
  Future<void> clear() async {
    await _c.invokeMethod<bool>('pendingClear', {'slot': 'add'});
  }
}

enum AddOutcome {
  /// Request sent and stored; wait for the other phone's approval.
  requested,

  /// add-begin said not approved (or was unreadable). Record kept, check later.
  notApprovedYet,

  /// The approval window passed without add-begin ever succeeding; record
  /// removed, key kept, the user may request again.
  approvalExpired,

  /// Typed 200 + matching keyId, native confirmation saved, record cleared.
  enrolled,

  /// A pending record (begun, finishSent or unreadable) is still live: no new
  /// request, the caller checks approval or reconciles it first.
  inProgress,

  /// Reconcile: the server already has this key; adopt it (never delete).
  needsAdopt,

  /// Reconcile: the server revoked this key; sign in with another method.
  revokedNeedsMethod,

  /// Reconcile: absent but the receipt window is not over yet.
  waiting,

  /// Reconcile: absent after the window; the record was cleared, may retry.
  absentCleared,

  /// Anything uncertain. The record (with token and signature) is kept.
  unknown,

  /// A check failed before any prompt or the user cancelled. Nothing sent.
  refused,
  notStarted,
}

class AddResult {
  const AddResult(this.outcome, {this.fingerprint, this.failure, this.keyId});
  final AddOutcome outcome;
  final String? fingerprint, keyId;
  final DeviceProofFailure? failure;
}

/// Second-phone driver (v8 5.3 + 8.4). No activation, no step-up.
class AddDeviceDriver {
  AddDeviceDriver({
    required this.source,
    required this.routes,
    required this.store,
    required this.ownerId,
    required this.sessionDeviceId,
    this.expectedGeneration,
    required this.onEnrolled,
    this.statusRoutes,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DeviceProofSource source;
  final AddDeviceRoutes routes;
  final AddPendingStore store;
  final String ownerId, sessionDeviceId;
  final int? expectedGeneration;
  final Future<void> Function(String keyId) onEnrolled;
  final DeviceStatusRoutes? statusRoutes;
  final int Function() _now;

  /// Step 1: create the key (no prompt), ask for approval, persist. A lost
  /// response is simply repeated with the same key (the server returns the
  /// same open request for the same digest).
  Future<AddResult> request() async {
    // Read the slot first: never overwrite a live record.
    final existing = await store.read();
    // Unknown (unreadable) pending may be a signed finish: never overwrite.
    if (existing.unreadable) return const AddResult(AddOutcome.inProgress);
    final er = existing.record;
    if (er != null) {
      if (er.ownerId != ownerId || er.sessionDeviceId != sessionDeviceId) {
        return const AddResult(AddOutcome.refused);
      }
      final ex = er.approvalExpiresAtMs;
      final expired =
          er.state == AddState.requested && ex != null && _now() > ex;
      if (!expired) {
        return er.state == AddState.requested
            ? AddResult(
                AddOutcome.requested,
                fingerprint: fingerprintOf(er.digest),
              )
            : const AddResult(AddOutcome.inProgress);
      }
    }
    final a = await source.availability();
    if (a != DeviceProofAvailability.available) {
      return const AddResult(AddOutcome.notStarted);
    }
    Map<String, String> jwk;
    try {
      jwk = spkiToJwk(await source.createKeyForEnrollment());
    } on DeviceProofFailure catch (e) {
      return AddResult(AddOutcome.notStarted, failure: e);
    } on FormatException {
      return const AddResult(AddOutcome.notStarted);
    }
    final start = _now();
    AddRequestReply? reply;
    try {
      reply = await routes.addRequest(jwk);
    } catch (_) {
      return const AddResult(AddOutcome.unknown);
    }
    if (reply == null ||
        reply.expiresAt <= start ||
        reply.expiresAt > start + maxApprovalLifetimeMs) {
      return const AddResult(AddOutcome.refused);
    }
    try {
      await store.write(
        AddPendingRecord(
          state: AddState.requested,
          ownerId: ownerId,
          sessionDeviceId: sessionDeviceId,
          changeId: reply.changeId,
          digest: publicKeyDigest(jwk),
          requestStartMs: start,
          approvalExpiresAtMs: reply.expiresAt,
        ),
      );
    } catch (_) {
      return const AddResult(AddOutcome.unknown);
    }
    return AddResult(AddOutcome.requested, fingerprint: reply.fingerprint);
  }

  /// Step 2: the user taps "Check approval". Validates the challenge against
  /// the OWN key before any prompt, then signs and finishes.
  Future<AddResult> checkApprovalAndFinish() async {
    final read = await store.read();
    final rec = read.record;
    if (rec == null) {
      return read.unreadable ? recover() : const AddResult(AddOutcome.refused);
    }
    if (rec.ownerId != ownerId || rec.sessionDeviceId != sessionDeviceId) {
      return const AddResult(AddOutcome.refused); // kept, never applied
    }
    if (rec.state == AddState.finishSent) return retryFinish();
    if (rec.state == AddState.recovering) return recover();
    final now = _now();
    final Uint8List? spki;
    try {
      spki = await source.publicKeyOrNull();
    } catch (_) {
      return const AddResult(AddOutcome.unknown);
    }
    if (spki == null) return const AddResult(AddOutcome.unknown);
    final jwk = spkiToJwk(spki);
    if (publicKeyDigest(jwk) != rec.digest) {
      return const AddResult(AddOutcome.refused);
    }
    EnrollChallenge? c;
    try {
      c = await routes.addBegin(rec.changeId);
    } catch (_) {
      return const AddResult(AddOutcome.unknown); // keep the record
    }
    if (c == null) {
      // Not approved yet (or an unreadable reply): NEVER wipe on this alone.
      final ex = rec.approvalExpiresAtMs;
      if (rec.state == AddState.requested && ex != null && now > ex + 30000) {
        await store.clear();
        return const AddResult(AddOutcome.approvalExpired);
      }
      return const AddResult(AddOutcome.notApprovedYet);
    }
    // Everything the OS prompt will vouch for, before the prompt.
    if (c.purpose != 'enroll' ||
        c.actionDigest != deviceEnrollmentAction(jwk) ||
        c.ownerId != ownerId ||
        (expectedGeneration != null && c.generation != expectedGeneration) ||
        c.expiresAt <= now ||
        c.expiresAt > now + maxChallengeLifetimeMs) {
      return const AddResult(AddOutcome.refused);
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
      return const AddResult(AddOutcome.refused);
    }
    try {
      await store.write(
        AddPendingRecord(
          state: AddState.begun,
          ownerId: ownerId,
          sessionDeviceId: sessionDeviceId,
          changeId: rec.changeId,
          digest: rec.digest,
          keyId: c.keyId,
          requestStartMs: rec.requestStartMs,
          approvalExpiresAtMs: rec.approvalExpiresAtMs,
          challengeExpiresAtMs: c.expiresAt,
        ),
      );
    } catch (_) {
      return const AddResult(AddOutcome.unknown);
    }
    Uint8List sig;
    try {
      sig = await source.sign(fields);
    } on DeviceProofFailure catch (e) {
      return AddResult(AddOutcome.refused, failure: e); // record kept
    }
    if (sig.length != 64) return const AddResult(AddOutcome.refused);
    try {
      await store.write(
        AddPendingRecord(
          state: AddState.finishSent,
          ownerId: ownerId,
          sessionDeviceId: sessionDeviceId,
          changeId: rec.changeId,
          digest: rec.digest,
          keyId: c.keyId,
          requestStartMs: rec.requestStartMs,
          approvalExpiresAtMs: rec.approvalExpiresAtMs,
          challengeExpiresAtMs: c.expiresAt,
          sentAtMs: _now(),
          token: c.token,
          signature: sig,
        ),
      );
    } catch (_) {
      return const AddResult(AddOutcome.unknown); // signed, never sent
    }
    return _send(rec.changeId, c, sig, c.keyId);
  }

  /// Repeats the identical stored finish within 10 minutes of the send. Past
  /// that the caller must reconcile through enroll-status; never resend.
  Future<AddResult> retryFinish() async {
    final rec = (await store.read()).record;
    if (rec == null ||
        rec.state != AddState.finishSent ||
        rec.ownerId != ownerId ||
        rec.sessionDeviceId != sessionDeviceId) {
      return const AddResult(AddOutcome.unknown);
    }
    final age = _now() - rec.sentAtMs!;
    if (age < 0 || age >= enrollReceiptWindowMs) return _reconcile(rec);
    final c = EnrollChallenge(
      token: rec.token!,
      ownerId: rec.ownerId,
      keyId: rec.keyId!,
      generation: 0,
      challenge: '',
      actionDigest: '',
      expiresAt: rec.challengeExpiresAtMs!,
    );
    return _send(rec.changeId, c, rec.signature!, rec.keyId!);
  }

  /// Unreadable slot (or a persisted recovery anchor): read-only local JWK and
  /// enroll-status. The start is persisted BEFORE the status call and kept on
  /// every later run, so the absent floor never resets. Never creates a key,
  /// never sends a finish, never deletes a key.
  Future<AddResult> recover() async {
    final r = statusRoutes;
    if (r == null) return const AddResult(AddOutcome.unknown);
    final read = await store.read();
    var rec = read.record;
    if (rec != null &&
        (rec.state != AddState.recovering ||
            rec.ownerId != ownerId ||
            rec.sessionDeviceId != sessionDeviceId)) {
      return const AddResult(AddOutcome.unknown);
    }
    if (rec == null) {
      if (!read.unreadable) return const AddResult(AddOutcome.refused);
      try {
        final spki = await source.publicKeyOrNull();
        if (spki == null) return const AddResult(AddOutcome.unknown);
        rec = AddPendingRecord(
          state: AddState.recovering,
          ownerId: ownerId,
          sessionDeviceId: sessionDeviceId,
          changeId: 'recovery',
          digest: publicKeyDigest(spkiToJwk(spki)),
          requestStartMs: _now(),
        );
        await store.write(rec);
      } catch (_) {
        return const AddResult(AddOutcome.unknown);
      }
    }
    return _statusOutcome(
      r,
      rec.digest,
      absentFloorMs(rec.requestStartMs, null),
    );
  }

  Future<AddResult> _statusOutcome(
    DeviceStatusRoutes r,
    String digest,
    int floor,
  ) async {
    ({ServerKeyStatus status, String? keyId})? st;
    try {
      st = await r.status(digest);
    } catch (_) {
      return const AddResult(AddOutcome.unknown);
    }
    if (st == null) return const AddResult(AddOutcome.unknown);
    switch (st.status) {
      case ServerKeyStatus.enrolled:
        return AddResult(AddOutcome.needsAdopt, keyId: st.keyId);
      case ServerKeyStatus.revoked:
        return const AddResult(AddOutcome.revokedNeedsMethod);
      case ServerKeyStatus.absent:
        if (_now() > floor) {
          await store.clear();
          return const AddResult(AddOutcome.absentCleared);
        }
        return const AddResult(AddOutcome.waiting);
    }
  }

  /// Past the replay window: read enroll-status for OUR digest. Never resend,
  /// never delete a key on unknown, absent or revoked.
  Future<AddResult> _reconcile(AddPendingRecord rec) async {
    final r = statusRoutes;
    if (r == null) return const AddResult(AddOutcome.unknown);
    return _statusOutcome(
      r,
      rec.digest,
      absentFloorMs(rec.sentAtMs!, rec.challengeExpiresAtMs),
    );
  }

  Future<AddResult> _send(
    String changeId,
    EnrollChallenge c,
    Uint8List sig,
    String keyId,
  ) async {
    try {
      final res = await routes.addFinish(changeId, c, sig);
      if (res.status == 200 && res.keyId == keyId) {
        await onEnrolled(keyId);
        await store.clear();
        return AddResult(AddOutcome.enrolled, keyId: keyId);
      }
    } catch (_) {}
    return const AddResult(AddOutcome.unknown); // record + bytes kept
  }
}

enum ApproveOutcome {
  approved,

  /// finish returned false/threw: the row is still pending. Never re-sign the
  /// same challenge; re-read status.
  notConfirmed,

  /// The row vanished after a lost finish: approved OR expired. Not success.
  approvedOrExpired,
  refused,
  cancelled,
}

/// Approver-side driver (an enrolled phone approving another method). The host
/// step-up signer is disabled, so nothing calls this yet.
class ApprovalDriver {
  ApprovalDriver({
    required this.source,
    required this.routes,
    required this.ownerId,
    required this.ownKeyId,
    required this.accountEmail,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DeviceProofSource source;
  final ApprovalRoutes routes;
  final String ownerId, ownKeyId, accountEmail;
  final int Function() _now;
  final _attempted = <String>{};

  Future<ApproveOutcome> approve(ApprovalStatus status, ApprovalRow row) async {
    // A challenge for this change was already signed: never sign it again.
    if (_attempted.contains(row.changeId)) return ApproveOutcome.notConfirmed;
    EnrollChallenge? c;
    try {
      c = await routes.approveBegin(row.changeId, ownKeyId);
    } catch (_) {
      return ApproveOutcome.refused;
    }
    if (c == null) return ApproveOutcome.refused;
    final prompt = validateApprovalChallenge(
      status: status,
      row: row,
      challenge: c,
      storedOwnerId: ownerId,
      ownKeyId: ownKeyId,
      accountEmail: accountEmail,
      nowMs: _now(),
    );
    if (prompt == null) return ApproveOutcome.refused;
    final DeviceProofFields fields;
    try {
      fields = DeviceProofFields(
        purpose: 'step-up',
        ownerId: c.ownerId,
        keyId: c.keyId,
        generation: c.generation,
        challenge: c.challenge,
        actionDigest: c.actionDigest,
        expiresAt: c.expiresAt,
      );
      fields.message;
    } on FormatException {
      return ApproveOutcome.refused;
    }
    Uint8List sig;
    try {
      sig = await source.sign(fields, displayText: prompt);
    } on DeviceProofFailure catch (e) {
      return e.kind == DeviceProofFailureKind.cancelled
          ? ApproveOutcome.cancelled
          : ApproveOutcome.refused;
    }
    if (sig.length != 64) return ApproveOutcome.refused;
    _attempted.add(row.changeId);
    var ok = false;
    try {
      ok = await routes.approveFinish(row.changeId, c.token, sig);
    } catch (_) {}
    if (ok) return ApproveOutcome.approved;
    // Lost or negative: re-read status, never re-sign the same challenge.
    try {
      final again = await routes.status();
      if (again != null &&
          again.pending.any((r) => r.changeId == row.changeId)) {
        return ApproveOutcome.notConfirmed;
      }
      if (again != null) return ApproveOutcome.approvedOrExpired;
    } catch (_) {}
    return ApproveOutcome.notConfirmed;
  }
}
