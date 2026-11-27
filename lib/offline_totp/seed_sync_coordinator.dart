import 'dart:async';

import 'native_seed_custody.dart';
import 'seed_sync_channel.dart';
import 'seed_sync_http.dart';

/// Inactive, unregistered orchestration of one seed-sync pull for the settled
/// contract: fresh key-signed snapshot, custody reconcile, then signed batches
/// whose sealed entries native opens straight into custody. Nothing here creates
/// a platform host, HTTP client, timer or session, and nothing schedules a run.
///
/// Rules this file enforces:
///  * Native owns every key, ephemeral key, proof, clock and sealed open. Dart
///    only carries opaque strings between the server and native. No seed byte,
///    private key or plaintext is an input or output here, and no secret store
///    is created.
///  * A fresh signed snapshot is applied to custody BEFORE any pull of the same
///    run. Pulls ask only for entries custody reported as needing a newer
///    version, at the exact version the snapshot listed.
///  * The enrollment must be CONFIRMED in native's journal, for the install the
///    caller named. The journal key id and generation, the owner's local epoch
///    and enabled flag, and the caller's own signed-in/sync-enabled check are
///    re-read before every step that spends a challenge, signs, releases or
///    opens. Any change stops the run with nothing further sent or opened.
///  * Nothing is retried, replaced, reset, erased or purged. A server answer of
///    `key-revoked` or `generation-changed` (only ever sent after a verified
///    signature) is reported as such. Acting on it is the caller's call, through
///    the key-signed status path, never from here.
///  * Every failure after a mutation is an unknown outcome. The run stops, the
///    native batch handle is abandoned (finish is best-effort cleanup only), and
///    the next run starts again from a fresh snapshot and a fresh custody read.

enum SeedSyncOutcome {
  /// Everything custody asked for was provisioned in this run, nothing else
  /// outstanding that this run could do.
  synced,

  /// Reconcile applied, but something stays outstanding: entries the server
  /// could not seal (stale, removed, unsupported), entries beyond a stop, or a
  /// physical delete still pending. Another run decides. See the result lists.
  partial,

  /// The server snapshot is revision 0 with no entries: nothing is authorized,
  /// custody was not touched (it refuses revision 0).
  emptyOwner,

  /// No confirmed enrollment for this owner (none, or prepared/signed only).
  notEnrolled,

  /// The journal belongs to another install id than the caller's.
  installMismatch,

  /// Signed out, switched, sync disabled, epoch moved or the enrollment
  /// changed before or during the run. Nothing was sent after.
  notCurrent,

  /// Verified server answer for our key. NOT acted on here.
  keyRevoked,
  generationChanged,

  /// A server challenge or answer disagrees with what native or the caller
  /// knows (owner, key, device, generation, epoch). Treat as hostile; nothing
  /// further was sent.
  challengeMismatch,

  /// Server or network unavailable, or an opaque refusal. Unknown outcome of
  /// whatever the failed request was; nothing is assumed released or not.
  serverUnavailable,

  /// A 200 reply that is not exactly the contract. Hostile or incompatible.
  serverMalformed,

  /// Native refused or is unavailable before anything was provisioned.
  nativeUnavailable,

  /// Custody reconcile refused: the snapshot is not newer than the last applied
  /// one (see the staleSnapshot note in the result).
  staleSnapshot,

  /// Custody refused the snapshot as invalid, or the owner is opted out/epoch
  /// differs. Nothing was applied.
  custodyRefused,

  /// A custody or native mutation failed with an unknown outcome. Re-read
  /// durable state before anything else.
  unknownOutcome,
}

enum SeedSyncEntryState {
  provisioned,

  /// The server answered stale, removed or unsupported for it. Consumed natively.
  skipped,

  /// Native open or the batch failed for it (see [SeedSyncEntryResult.failure]).
  failed,

  /// Never requested: a stop, or the entry is not provisionable.
  notAttempted,
}

final class SeedSyncEntryResult {
  const SeedSyncEntryResult(
    this.entryId,
    this.state, {
    this.serverStatus,
    this.failure,
  });
  final String entryId;
  final SeedSyncEntryState state;
  final SeedSyncResultStatus? serverStatus;
  final SeedSyncFailureKind? failure;
}

final class SeedSyncResult {
  SeedSyncResult(
    this.outcome, {
    this.revision,
    this.removed = const [],
    this.superseded = const [],
    this.pendingPurge = const [],
    this.unprovisionable = const [],
    List<SeedSyncEntryResult> entries = const [],
  }) : entries = List.unmodifiable(entries);
  final SeedSyncOutcome outcome;

  /// Revision of the snapshot custody applied, when it did.
  final int? revision;
  final List<String> removed, superseded, pendingPurge;

  /// Needed by custody but the server listed them as unsupported or not at all.
  final List<String> unprovisionable;
  final List<SeedSyncEntryResult> entries;
  @override
  String toString() => 'SeedSyncResult(${outcome.name})';
}

/// What the caller already knows and must keep current. [deviceId] is optional:
/// when given it must equal the server session's device id, otherwise the one the
/// first signed challenge states is used for the whole run.
final class SeedSyncScope {
  const SeedSyncScope({
    required this.owner,
    required this.installId,
    required this.epoch,
    this.deviceId,
  });
  final String owner, installId;
  final int epoch;
  final String? deviceId;
  bool sameAs(SeedSyncScope o) =>
      owner == o.owner &&
      installId == o.installId &&
      epoch == o.epoch &&
      deviceId == o.deviceId;
}

/// Whether [owner] is still the signed-in owner with key sync enabled.
typedef SeedSyncCurrent = Future<bool> Function(String owner);

abstract interface class SeedSyncNative {
  Future<SeedEnrollmentJournal?> journal(String owner);
  Future<String> snapshotProof({
    required String owner,
    required String keyId,
    required String deviceId,
    required int generation,
    required int epoch,
    required String challenge,
    required int expiresAt,
  });
  Future<SeedBatchStart> begin({
    required String owner,
    required String deviceId,
    required int generation,
    required int epoch,
    required List<SeedBatchEntry> entries,
  });
  Future<void> bind(
    String handleId, {
    required String challenge,
    required int expiresAt,
  });
  Future<String> signBatch(String handleId);
  Future<List<String>> open(
    String handleId, {
    required String entryId,
    required String serverPublicKey,
    required String nonce,
    required String ciphertext,
  });
  Future<List<String>> skip(String handleId, String entryId);
  Future<void> finish(String handleId);
}

final class SeedSyncNativeAdapter implements SeedSyncNative {
  SeedSyncNativeAdapter(this.channel);
  final SeedSyncChannel channel;
  @override
  Future<SeedEnrollmentJournal?> journal(String owner) =>
      channel.enrollmentJournal(owner);
  @override
  Future<String> snapshotProof({
    required String owner,
    required String keyId,
    required String deviceId,
    required int generation,
    required int epoch,
    required String challenge,
    required int expiresAt,
  }) => channel.snapshotProof(
    owner: owner,
    keyId: keyId,
    deviceId: deviceId,
    generation: generation,
    epoch: epoch,
    challenge: challenge,
    expiresAt: expiresAt,
  );
  @override
  Future<SeedBatchStart> begin({
    required String owner,
    required String deviceId,
    required int generation,
    required int epoch,
    required List<SeedBatchEntry> entries,
  }) => channel.begin(
    owner: owner,
    deviceId: deviceId,
    generation: generation,
    epoch: epoch,
    entries: entries,
  );
  @override
  Future<void> bind(
    String handleId, {
    required String challenge,
    required int expiresAt,
  }) => channel.bind(handleId, challenge: challenge, expiresAt: expiresAt);
  @override
  Future<String> signBatch(String handleId) => channel.signBatch(handleId);
  @override
  Future<List<String>> open(
    String handleId, {
    required String entryId,
    required String serverPublicKey,
    required String nonce,
    required String ciphertext,
  }) => channel.open(
    handleId,
    entryId: entryId,
    serverPublicKey: serverPublicKey,
    nonce: nonce,
    ciphertext: ciphertext,
  );
  @override
  Future<List<String>> skip(String handleId, String entryId) =>
      channel.skip(handleId, entryId);
  @override
  Future<void> finish(String handleId) => channel.finish(handleId);
}

/// Thrown internally to end a run with one outcome.
final class _Stop implements Exception {
  _Stop(this.outcome);
  final SeedSyncOutcome outcome;
}

final class SeedSyncCoordinator {
  SeedSyncCoordinator({
    required this._api,
    required this._native,
    required this._custody,
    required this._current,
  });
  final SeedSyncPullApi _api;
  final SeedSyncNative _native;
  final NativeSeedCustody _custody;
  final SeedSyncCurrent _current;

  Future<SeedSyncResult>? _running;
  SeedSyncScope? _runningScope;
  Future<void> _tail = Future<void>.value();

  /// One pull. Concurrent callers with the same scope share the run; a different
  /// scope waits for it. Never throws.
  Future<SeedSyncResult> sync(SeedSyncScope scope) {
    final running = _running;
    if (running != null && _runningScope!.sameAs(scope)) return running;
    final run = _tail
        .then((_) => _run(scope))
        .catchError(
          (Object _) => SeedSyncResult(SeedSyncOutcome.unknownOutcome),
        );
    _tail = run.then<void>((_) {});
    _running = run;
    _runningScope = scope;
    run.whenComplete(() {
      if (identical(_running, run)) {
        _running = null;
        _runningScope = null;
      }
    });
    return run;
  }

  /// Re-reads everything a step depends on. Throws [_Stop].
  Future<SeedEnrollmentJournal> _check(
    SeedSyncScope scope,
    SeedEnrollmentJournal? pinned,
  ) async {
    bool signedIn;
    CustodyOwnerState state;
    SeedEnrollmentJournal? journal;
    try {
      signedIn = await _current(scope.owner);
      state = await _custody.readOwnerState(scope.owner);
      journal = await _native.journal(scope.owner);
    } catch (_) {
      throw _Stop(SeedSyncOutcome.nativeUnavailable);
    }
    if (!signedIn || !state.enabled || state.epoch != scope.epoch) {
      throw _Stop(SeedSyncOutcome.notCurrent);
    }
    if (journal == null || journal.phase != SeedEnrollmentPhase.confirmed) {
      throw _Stop(
        pinned == null
            ? SeedSyncOutcome.notEnrolled
            : SeedSyncOutcome.notCurrent,
      );
    }
    if (journal.installId != scope.installId) {
      throw _Stop(
        pinned == null
            ? SeedSyncOutcome.installMismatch
            : SeedSyncOutcome.notCurrent,
      );
    }
    if (pinned != null &&
        (journal.keyId != pinned.keyId ||
            journal.generation != pinned.generation ||
            journal.installId != pinned.installId)) {
      throw _Stop(SeedSyncOutcome.notCurrent);
    }
    return journal;
  }

  Future<T> _server<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SeedSyncSignedStateException catch (e) {
      throw _Stop(
        e.state == SeedSyncSignedState.keyRevoked
            ? SeedSyncOutcome.keyRevoked
            : SeedSyncOutcome.generationChanged,
      );
    } on SeedSyncPullException catch (e) {
      throw _Stop(
        e.reason == SeedSyncPullFailure.shape
            ? SeedSyncOutcome.serverMalformed
            : SeedSyncOutcome.serverUnavailable,
      );
    } on ArgumentError {
      throw _Stop(SeedSyncOutcome.serverMalformed);
    } catch (_) {
      throw _Stop(SeedSyncOutcome.serverUnavailable);
    }
  }

  Future<SeedSyncResult> _run(SeedSyncScope scope) async {
    var journal = await _guarded(() => _check(scope, null));
    if (journal is _Stop) return SeedSyncResult(journal.outcome);
    final pinned = journal as SeedEnrollmentJournal;
    int? revision;
    var removed = <String>[],
        superseded = <String>[],
        pendingPurge = <String>[];
    var unprovisionable = <String>[];
    final entries = <SeedSyncEntryResult>[];
    SeedSyncOutcome? stopped;
    try {
      // 1. Fresh signed snapshot.
      final challenge = await _server(
        () => _api.snapshotBegin(keyId: pinned.keyId, epoch: scope.epoch),
      );
      if (challenge.ownerId != scope.owner ||
          challenge.generation != pinned.generation ||
          (scope.deviceId != null && challenge.deviceId != scope.deviceId)) {
        throw _Stop(SeedSyncOutcome.challengeMismatch);
      }
      await _check(scope, pinned);
      String proof;
      try {
        proof = await _native.snapshotProof(
          owner: scope.owner,
          keyId: pinned.keyId,
          deviceId: challenge.deviceId,
          generation: pinned.generation,
          epoch: scope.epoch,
          challenge: challenge.challenge,
          expiresAt: challenge.expiresAt,
        );
      } catch (_) {
        throw _Stop(SeedSyncOutcome.nativeUnavailable);
      }
      await _check(scope, pinned);
      final snapshot = await _server(
        () => _api.snapshotFinish(challenge: challenge, signature: proof),
      );
      final deviceId = challenge.deviceId;
      revision = snapshot.revision;

      // 2. Apply to custody before any pull.
      await _check(scope, pinned);
      if (snapshot.revision == 0) {
        if (snapshot.entries.isNotEmpty || snapshot.tombstones.isNotEmpty) {
          throw _Stop(SeedSyncOutcome.serverMalformed);
        }
        return SeedSyncResult(SeedSyncOutcome.emptyOwner, revision: 0);
      }
      ReconcileResult reconciled;
      try {
        reconciled = await _custody.reconcile(
          scope.owner,
          CustodySnapshot(
            epoch: scope.epoch,
            revision: snapshot.revision,
            complete: snapshot.complete,
            versions: {
              for (final e in snapshot.entries) e.entryId: e.seedVersion,
            },
            tombstones: snapshot.tombstones,
            preserve: snapshot.unsupported.keys.toSet(),
          ),
        );
      } on CustodyException catch (e) {
        throw _Stop(switch (e.error) {
          CustodyError.staleSnapshot => SeedSyncOutcome.staleSnapshot,
          CustodyError.invalidSnapshot ||
          CustodyError.disabled ||
          CustodyError.staleEpoch ||
          CustodyError.epochMismatch => SeedSyncOutcome.custodyRefused,
          _ => SeedSyncOutcome.unknownOutcome,
        });
      } catch (_) {
        throw _Stop(SeedSyncOutcome.unknownOutcome);
      }
      removed = reconciled.removed;
      superseded = reconciled.superseded;
      pendingPurge = reconciled.pendingPurge;

      // 3. Pull only what custody needs, at the snapshot's exact versions.
      final byId = {for (final e in snapshot.entries) e.entryId: e};
      final need = [...reconciled.needsProvision]..sort();
      final pull = <SeedSyncSnapshotEntry>[];
      for (final id in need) {
        final e = byId[id];
        if (e == null) {
          unprovisionable.add(id);
          entries.add(SeedSyncEntryResult(id, SeedSyncEntryState.notAttempted));
        } else {
          pull.add(e);
        }
      }
      final size = snapshot.maxBatch < 3 ? snapshot.maxBatch : 3;
      for (var i = 0; i < pull.length && stopped == null; i += size) {
        final end = i + size < pull.length ? i + size : pull.length;
        stopped = await _batch(
          scope,
          pinned,
          deviceId,
          pull.sublist(i, end),
          entries,
        );
      }
      if (stopped != null) {
        final done = entries.map((e) => e.entryId).toSet();
        for (final e in pull) {
          if (!done.contains(e.entryId)) {
            entries.add(
              SeedSyncEntryResult(e.entryId, SeedSyncEntryState.notAttempted),
            );
          }
        }
        return SeedSyncResult(
          stopped,
          revision: revision,
          removed: removed,
          superseded: superseded,
          pendingPurge: pendingPurge,
          unprovisionable: unprovisionable,
          entries: entries,
        );
      }
    } on _Stop catch (s) {
      return SeedSyncResult(
        s.outcome,
        revision:
            s.outcome == SeedSyncOutcome.unknownOutcome ||
                s.outcome == SeedSyncOutcome.staleSnapshot
            ? null
            : revision,
        removed: removed,
        superseded: superseded,
        pendingPurge: pendingPurge,
        unprovisionable: unprovisionable,
        entries: entries,
      );
    }
    final clean =
        unprovisionable.isEmpty &&
        pendingPurge.isEmpty &&
        entries.every((e) => e.state == SeedSyncEntryState.provisioned);
    return SeedSyncResult(
      clean ? SeedSyncOutcome.synced : SeedSyncOutcome.partial,
      revision: revision,
      removed: removed,
      superseded: superseded,
      pendingPurge: pendingPurge,
      unprovisionable: unprovisionable,
      entries: entries,
    );
  }

  Future<Object> _guarded(Future<Object> Function() f) async {
    try {
      return await f();
    } on _Stop catch (s) {
      return s;
    }
  }

  /// One signed batch. Returns null to continue or the outcome that stops the run.
  Future<SeedSyncOutcome?> _batch(
    SeedSyncScope scope,
    SeedEnrollmentJournal pinned,
    String deviceId,
    List<SeedSyncSnapshotEntry> want,
    List<SeedSyncEntryResult> out,
  ) async {
    String? handle;
    try {
      await _check(scope, pinned);
      SeedBatchStart start;
      try {
        start = await _native.begin(
          owner: scope.owner,
          deviceId: deviceId,
          generation: pinned.generation,
          epoch: scope.epoch,
          entries: [
            for (final e in want)
              SeedBatchEntry(
                e.entryId,
                e.seedVersion,
                e.algorithm,
                e.digits,
                e.period,
              ),
          ],
        );
      } on SeedSyncFailure catch (e) {
        // No handle id came back: it may still occupy a native slot until its
        // TTL. Never an erase reason, never retried here.
        return e.kind == SeedSyncFailureKind.unknownOutcome
            ? SeedSyncOutcome.unknownOutcome
            : SeedSyncOutcome.nativeUnavailable;
      } catch (_) {
        return SeedSyncOutcome.unknownOutcome;
      }
      handle = start.handleId;
      final challenge = await _server(
        () => _api.batchBegin(
          keyId: pinned.keyId,
          epoch: scope.epoch,
          ephemeralKey: start.ephemeralPublic,
          entries: [
            for (final e in want)
              (entryId: e.entryId, seedVersion: e.seedVersion),
          ],
        ),
      );
      if (challenge.ownerId != scope.owner ||
          challenge.deviceId != deviceId ||
          challenge.generation != pinned.generation) {
        throw _Stop(SeedSyncOutcome.challengeMismatch);
      }
      await _check(scope, pinned);
      try {
        await _native.bind(
          handle,
          challenge: challenge.challenge,
          expiresAt: challenge.expiresAt,
        );
      } catch (_) {
        throw _Stop(SeedSyncOutcome.unknownOutcome);
      }
      await _check(scope, pinned);
      String signature;
      try {
        signature = await _native.signBatch(handle);
      } catch (_) {
        throw _Stop(SeedSyncOutcome.unknownOutcome);
      }
      await _check(scope, pinned);
      final batch = await _server(
        () => _api.batchFinish(challenge: challenge, signature: signature),
      );
      // The answer must cover exactly the requested set, with sealed metadata
      // equal to the snapshot's. Anything else is not this request's answer.
      final wantById = {for (final e in want) e.entryId: e};
      if (batch.results.length != want.length ||
          batch.results.any((r) => !wantById.containsKey(r.entryId))) {
        throw _Stop(SeedSyncOutcome.serverMalformed);
      }
      for (final r in batch.results) {
        final e = wantById[r.entryId]!;
        if (r.status == SeedSyncResultStatus.sealed &&
            (r.seedVersion != e.seedVersion ||
                r.algorithm != e.algorithm ||
                r.digits != e.digits ||
                r.period != e.period)) {
          throw _Stop(SeedSyncOutcome.serverMalformed);
        }
      }
      final byResult = {for (final r in batch.results) r.entryId: r};
      for (final e in want) {
        final r = byResult[e.entryId]!;
        await _check(scope, pinned);
        try {
          if (r.status == SeedSyncResultStatus.sealed) {
            await _native.open(
              handle,
              entryId: e.entryId,
              serverPublicKey: batch.serverPublicKey!,
              nonce: r.nonce!,
              ciphertext: r.ciphertext!,
            );
            out.add(
              SeedSyncEntryResult(
                e.entryId,
                SeedSyncEntryState.provisioned,
                serverStatus: r.status,
              ),
            );
          } else {
            await _native.skip(handle, e.entryId);
            out.add(
              SeedSyncEntryResult(
                e.entryId,
                SeedSyncEntryState.skipped,
                serverStatus: r.status,
              ),
            );
          }
        } on SeedSyncFailure catch (f) {
          // Native discards the handle on any open failure. Outcome of this
          // entry is unknown (custody may have provisioned before replying).
          out.add(
            SeedSyncEntryResult(
              e.entryId,
              SeedSyncEntryState.failed,
              serverStatus: r.status,
              failure: f.kind,
            ),
          );
          return f.kind == SeedSyncFailureKind.unknownOutcome
              ? SeedSyncOutcome.unknownOutcome
              : SeedSyncOutcome.nativeUnavailable;
        } catch (_) {
          out.add(
            SeedSyncEntryResult(
              e.entryId,
              SeedSyncEntryState.failed,
              serverStatus: r.status,
              failure: SeedSyncFailureKind.unknownOutcome,
            ),
          );
          return SeedSyncOutcome.unknownOutcome;
        }
      }
      return null;
    } on _Stop catch (s) {
      return s.outcome;
    } finally {
      if (handle != null) {
        try {
          await _native.finish(handle);
        } catch (_) {
          // Best-effort cleanup. The native handle expires on its own.
        }
      }
    }
  }
}
