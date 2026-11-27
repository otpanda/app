import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'seed_sync_channel.dart';

/// Inactive, unregistered coordinator for the settled v2 enrollment contract:
/// context, native prepare, passkey step-up, enroll-begin, native sign, enroll-finish,
/// then confirm. Nothing here creates a platform host, HTTP client or passkey UI.
///
/// Rules this file enforces:
///  * Native owns the durable journal (prepared, signed, confirmed). Every run starts
///    from it. A prepared key resumes with its own key id and public point.
///  * Nothing replaces, resets or purges a key. A stale generation, a missing server
///    answer or an opaque status preserves state and returns a recoverable outcome.
///    A separately fenced reset is a different, explicitly approved operation.
///  * A signed attempt is an unknown outcome. Sign and finish are never repeated for
///    it. Only a key-signed status `active` for the exact key id confirms.
///  * The account and the sync setting are re-checked before every step that
///    spends a challenge, signs or finishes.

enum SeedEnrollOutcome {
  /// Server committed and native recorded confirmation in this run.
  confirmed,

  /// Journal was already confirmed. No network was used.
  alreadyConfirmed,

  /// A signature exists. The server result is unknown. Reconcile through status later.
  pendingServerOutcome,

  /// Server generation moved since the key was prepared. State preserved.
  staleGeneration,

  /// The signed key is revoked or superseded on the server and was never confirmed.
  /// Needs the separately fenced reset. State preserved.
  revokedUnconfirmed,

  /// The server reports a generation change for a signed key. State preserved.
  generationChangedUnconfirmed,

  /// The owner signed out, switched or disabled key sync mid-run. Nothing was sent after.
  notCurrent,

  /// The journal belongs to another install id. Nothing was sent.
  installMismatch,

  /// Server challenge disagrees with the native journal (owner, key, install, generation).
  challengeMismatch,

  /// Native refused to sign because the server action digest is not the one it computes.
  actionMismatch,

  /// Server or network unavailable before any signature. State preserved. Retry later.
  serverUnavailable,

  /// Native unavailable or a non-recoverable native failure. State preserved.
  nativeUnavailable,
}

final class SeedEnrollResult {
  const SeedEnrollResult(this.outcome, {this.keyId});
  final SeedEnrollOutcome outcome;
  final String? keyId;
  @override
  String toString() => 'SeedEnrollResult(${outcome.name})';
}

enum SeedServerKeyState { active, revoked, generationChanged, unknown }

final class SeedStepUpBegin {
  const SeedStepUpBegin(this.token, this.options);
  final String token;

  /// Opaque passkey request options for the platform passkey asserter.
  final Object options;
}

final class SeedEnrollChallenge {
  const SeedEnrollChallenge({
    required this.token,
    required this.ownerId,
    required this.keyId,
    required this.installId,
    required this.generation,
    required this.challenge,
    required this.actionDigest,
    required this.expiresAt,
  });
  final String token, ownerId, keyId, installId, challenge, actionDigest;
  final int generation, expiresAt;
}

/// Server side of the contract. Implementations map every failure to an exception.
/// The server answers every state failure with an opaque 409, so a failure never
/// proves an operation did not commit.
abstract interface class SeedEnrollmentApi {
  Future<int> context();
  Future<SeedStepUpBegin> stepUpBegin({
    required String installId,
    required String keyId,
    required Map<String, String> publicJwk,
  });
  Future<SeedEnrollChallenge> enrollBegin({
    required String installId,
    required String keyId,
    required Map<String, String> publicJwk,
    required Object assertion,
    required String token,
  });

  /// True only when the server returned a successful finish. Anything else,
  /// including a thrown error or timeout, is unknown.
  Future<bool> enrollFinish({required String signature, required String token});

  /// Key-signed status for [keyId]. Opaque or failed answers are `unknown`.
  Future<SeedServerKeyState> keyStatus({
    required String owner,
    required String keyId,
  });
}

abstract interface class SeedPasskeyAsserter {
  /// Throws when the user cancels or the platform fails.
  Future<Object> assertStepUp(Object options);
}

/// Whether [owner] is still the signed-in owner with key sync enabled.
typedef SeedEnrollmentGuard = Future<bool> Function(String owner);

abstract interface class SeedEnrollmentNative {
  Future<SeedEnrollmentJournal?> journal(String owner);
  Future<SeedEnrollment> prepare({
    required String owner,
    required String installId,
    required int generation,
  });
  Future<String> signEnroll({
    required String owner,
    required String keyId,
    required String challenge,
    required String actionDigest,
    required int expiresAt,
  });
  Future<bool> confirm({
    required String owner,
    required String keyId,
    required String actionDigest,
  });
}

final class SeedEnrollmentNativeAdapter implements SeedEnrollmentNative {
  SeedEnrollmentNativeAdapter(this.channel);
  final SeedSyncChannel channel;
  @override
  Future<SeedEnrollmentJournal?> journal(String owner) =>
      channel.enrollmentJournal(owner);
  @override
  Future<SeedEnrollment> prepare({
    required String owner,
    required String installId,
    required int generation,
  }) => channel.prepareEnrollment(
    owner: owner,
    installId: installId,
    generation: generation,
  );
  @override
  Future<String> signEnroll({
    required String owner,
    required String keyId,
    required String challenge,
    required String actionDigest,
    required int expiresAt,
  }) => channel.enrollProof(
    owner: owner,
    keyId: keyId,
    challenge: challenge,
    actionDigest: actionDigest,
    expiresAt: expiresAt,
  );
  @override
  Future<bool> confirm({
    required String owner,
    required String keyId,
    required String actionDigest,
  }) => channel.confirmEnrollment(
    owner: owner,
    keyId: keyId,
    actionDigest: actionDigest,
  );
}

/// JWK for a native uncompressed P-256 point, in the member order the server hashes.
Map<String, String> seedPublicJwk(Uint8List point) {
  if (point.length != 65 || point[0] != 4) {
    throw ArgumentError('uncompressed P-256 point required');
  }
  String b64(List<int> b) => base64UrlEncode(b).replaceAll('=', '');
  return {
    'kty': 'EC',
    'crv': 'P-256',
    'x': b64(point.sublist(1, 33)),
    'y': b64(point.sublist(33, 65)),
  };
}

final class SeedEnrollmentCoordinator {
  SeedEnrollmentCoordinator({
    required this.native,
    required this.api,
    required this.passkey,
    required this.isCurrent,
  });
  final SeedEnrollmentNative native;
  final SeedEnrollmentApi api;
  final SeedPasskeyAsserter passkey;
  final SeedEnrollmentGuard isCurrent;
  final _running = <String, Future<SeedEnrollResult>>{};

  /// One run per owner at a time. A concurrent caller shares the running result.
  Future<SeedEnrollResult> run({
    required String owner,
    required String installId,
  }) => _running.putIfAbsent(
    owner,
    () => _run(owner, installId).whenComplete(() {
      _running.remove(owner);
    }),
  );

  Future<bool> _current(String owner) async {
    try {
      return await isCurrent(owner);
    } catch (_) {
      return false;
    }
  }

  SeedEnrollResult _r(SeedEnrollOutcome o, [String? key]) =>
      SeedEnrollResult(o, keyId: key);

  Future<SeedEnrollResult> _run(String owner, String installId) async {
    SeedEnrollmentJournal? journal;
    try {
      journal = await native.journal(owner);
    } catch (_) {
      return _r(SeedEnrollOutcome.nativeUnavailable);
    }
    if (!await _current(owner)) return _r(SeedEnrollOutcome.notCurrent);
    if (journal == null) {
      final int generation;
      try {
        generation = await api.context();
      } catch (_) {
        return _r(SeedEnrollOutcome.serverUnavailable);
      }
      if (!await _current(owner)) return _r(SeedEnrollOutcome.notCurrent);
      try {
        await native.prepare(
          owner: owner,
          installId: installId,
          generation: generation,
        );
      } on SeedSyncFailure catch (e) {
        // A lost reply may still have created the key. Read the journal and go on
        // from whatever is durable. Never call prepare a second time.
        if (e.kind != SeedSyncFailureKind.unknownOutcome) {
          return _r(SeedEnrollOutcome.nativeUnavailable);
        }
      } catch (_) {
        return _r(SeedEnrollOutcome.nativeUnavailable);
      }
      try {
        journal = await native.journal(owner);
      } catch (_) {
        return _r(SeedEnrollOutcome.nativeUnavailable);
      }
      if (journal == null) return _r(SeedEnrollOutcome.nativeUnavailable);
    }
    if (journal.installId != installId) {
      return _r(SeedEnrollOutcome.installMismatch, journal.keyId);
    }
    return switch (journal.phase) {
      SeedEnrollmentPhase.confirmed => _r(
        SeedEnrollOutcome.alreadyConfirmed,
        journal.keyId,
      ),
      SeedEnrollmentPhase.signed => _reconcile(owner, journal),
      SeedEnrollmentPhase.prepared => _enroll(owner, journal),
    };
  }

  /// Signed: the signature may have reached the server. Never sign or finish again.
  Future<SeedEnrollResult> _reconcile(
    String owner,
    SeedEnrollmentJournal j,
  ) async {
    final SeedServerKeyState state;
    try {
      state = await api.keyStatus(owner: owner, keyId: j.keyId);
    } catch (_) {
      return _r(SeedEnrollOutcome.pendingServerOutcome, j.keyId);
    }
    switch (state) {
      case SeedServerKeyState.active:
        if (!await _current(owner)) return _r(SeedEnrollOutcome.notCurrent);
        return _confirm(owner, j.keyId, j.actionDigest!);
      case SeedServerKeyState.revoked:
        return _r(SeedEnrollOutcome.revokedUnconfirmed, j.keyId);
      case SeedServerKeyState.generationChanged:
        return _r(SeedEnrollOutcome.generationChangedUnconfirmed, j.keyId);
      case SeedServerKeyState.unknown:
        return _r(SeedEnrollOutcome.pendingServerOutcome, j.keyId);
    }
  }

  Future<SeedEnrollResult> _confirm(
    String owner,
    String keyId,
    String digest,
  ) async {
    try {
      final ok = await native.confirm(
        owner: owner,
        keyId: keyId,
        actionDigest: digest,
      );
      return ok
          ? _r(SeedEnrollOutcome.confirmed, keyId)
          : _r(SeedEnrollOutcome.pendingServerOutcome, keyId);
    } catch (_) {
      // Server accepted but native could not record it. The journal stays signed
      // and the next run reconciles through status again.
      return _r(SeedEnrollOutcome.pendingServerOutcome, keyId);
    }
  }

  Future<SeedEnrollResult> _enroll(
    String owner,
    SeedEnrollmentJournal j,
  ) async {
    final jwk = seedPublicJwk(j.publicKey);
    final int generation;
    try {
      generation = await api.context();
    } catch (_) {
      return _r(SeedEnrollOutcome.serverUnavailable, j.keyId);
    }
    if (generation != j.generation) {
      return _r(SeedEnrollOutcome.staleGeneration, j.keyId);
    }
    if (!await _current(owner)) return _r(SeedEnrollOutcome.notCurrent);
    final SeedEnrollChallenge challenge;
    try {
      final step = await api.stepUpBegin(
        installId: j.installId,
        keyId: j.keyId,
        publicJwk: jwk,
      );
      final assertion = await passkey.assertStepUp(step.options);
      if (!await _current(owner)) return _r(SeedEnrollOutcome.notCurrent);
      challenge = await api.enrollBegin(
        installId: j.installId,
        keyId: j.keyId,
        publicJwk: jwk,
        assertion: assertion,
        token: step.token,
      );
    } catch (_) {
      return _r(SeedEnrollOutcome.serverUnavailable, j.keyId);
    }
    if (challenge.ownerId != owner ||
        challenge.keyId != j.keyId ||
        challenge.installId != j.installId ||
        challenge.generation != j.generation) {
      return _r(SeedEnrollOutcome.challengeMismatch, j.keyId);
    }
    if (!await _current(owner)) return _r(SeedEnrollOutcome.notCurrent);
    final String signature;
    try {
      signature = await native.signEnroll(
        owner: owner,
        keyId: j.keyId,
        challenge: challenge.challenge,
        actionDigest: challenge.actionDigest,
        expiresAt: challenge.expiresAt,
      );
    } on SeedSyncFailure catch (e) {
      if (e.kind == SeedSyncFailureKind.wire) {
        // Native recomputed the digest and refused. Nothing was journaled or signed.
        return _r(SeedEnrollOutcome.actionMismatch, j.keyId);
      }
      // A lost reply may have journaled "signed". The signature is gone, so the
      // server can never commit this attempt. State is preserved for a reset.
      return _r(
        e.kind == SeedSyncFailureKind.unknownOutcome
            ? SeedEnrollOutcome.pendingServerOutcome
            : SeedEnrollOutcome.nativeUnavailable,
        j.keyId,
      );
    } catch (_) {
      return _r(SeedEnrollOutcome.nativeUnavailable, j.keyId);
    }
    // Signed now. Finish is sent at most once. After sign, every failure is unknown.
    if (!await _current(owner)) {
      return _r(SeedEnrollOutcome.notCurrent, j.keyId);
    }
    bool committed;
    try {
      committed = await api.enrollFinish(
        signature: signature,
        token: challenge.token,
      );
    } catch (_) {
      committed = false;
    }
    if (!committed) return _r(SeedEnrollOutcome.pendingServerOutcome, j.keyId);
    return _confirm(owner, j.keyId, challenge.actionDigest);
  }
}
