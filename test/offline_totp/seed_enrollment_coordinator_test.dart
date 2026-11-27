import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_enrollment_coordinator.dart';
import 'package:otpanda_client/offline_totp/seed_sync_channel.dart';

final _install = 'I' * 43;
final _key = 'c' * 32;
final _digest = 'd' * 64;
final _point = Uint8List.fromList([4, ...List.generate(64, (i) => i + 1)]);
final _sig = base64UrlEncode(List.filled(64, 1)).replaceAll('=', '');

/// Durable native state shared across simulated restarts. Mirrors the Kotlin
/// rules: create-only prepare, journal "signed" before a signature is returned,
/// no signing once confirmed, confirm only for the exact signed tuple.
class FakeNative implements SeedEnrollmentNative {
  SeedEnrollmentJournal? stored;
  final calls = <String>[];
  SeedSyncFailureKind? prepareFail, signFail, confirmFail;
  bool prepareLandsBeforeFail = false, signLandsBeforeFail = false;
  bool refuseDigest = false;

  @override
  Future<SeedEnrollmentJournal?> journal(String owner) async {
    calls.add('journal');
    return stored;
  }

  @override
  Future<SeedEnrollment> prepare({
    required String owner,
    required String installId,
    required int generation,
  }) async {
    calls.add('prepare');
    if (stored != null) {
      throw const SeedSyncFailure(SeedSyncFailureKind.eraseIncomplete);
    }
    if (prepareFail != null && !prepareLandsBeforeFail) {
      throw SeedSyncFailure(prepareFail!);
    }
    stored = SeedEnrollmentJournal(
      _key,
      _point,
      installId,
      generation,
      SeedEnrollmentPhase.prepared,
      null,
    );
    if (prepareFail != null) throw SeedSyncFailure(prepareFail!);
    return SeedEnrollment(_key, _point, generation, installId);
  }

  @override
  Future<String> signEnroll({
    required String owner,
    required String keyId,
    required String challenge,
    required String actionDigest,
    required int expiresAt,
  }) async {
    calls.add('sign');
    final j = stored;
    if (j == null || j.keyId != keyId) {
      throw const SeedSyncFailure(SeedSyncFailureKind.wire);
    }
    if (j.phase == SeedEnrollmentPhase.confirmed) {
      throw const SeedSyncFailure(SeedSyncFailureKind.invalidInput);
    }
    if (refuseDigest) throw const SeedSyncFailure(SeedSyncFailureKind.wire);
    if (signFail != null && !signLandsBeforeFail) {
      throw SeedSyncFailure(signFail!);
    }
    stored = SeedEnrollmentJournal(
      j.keyId,
      j.publicKey,
      j.installId,
      j.generation,
      SeedEnrollmentPhase.signed,
      actionDigest,
    );
    if (signFail != null) throw SeedSyncFailure(signFail!);
    return _sig;
  }

  @override
  Future<bool> confirm({
    required String owner,
    required String keyId,
    required String actionDigest,
  }) async {
    calls.add('confirm');
    if (confirmFail != null) throw SeedSyncFailure(confirmFail!);
    final j = stored;
    if (j == null ||
        j.keyId != keyId ||
        j.actionDigest != actionDigest ||
        j.phase == SeedEnrollmentPhase.prepared) {
      return false;
    }
    stored = SeedEnrollmentJournal(
      j.keyId,
      j.publicKey,
      j.installId,
      j.generation,
      SeedEnrollmentPhase.confirmed,
      j.actionDigest,
    );
    return true;
  }
}

class FakeApi implements SeedEnrollmentApi {
  final calls = <String>[];
  int generation = 3;
  bool contextFails = false, stepUpFails = false, enrollBeginFails = false;
  bool finishCommits = true, finishThrows = false;
  bool committed = false, commitBeforeThrow = false;
  SeedServerKeyState status = SeedServerKeyState.unknown;
  bool statusThrows = false;
  String challengeOwner = 'owner', challengeKey = _key;
  String challengeInstall = _install;
  int? challengeGeneration;
  String actionDigest = _digest;
  Map<String, String>? lastJwk;
  void Function(String call)? onCall;

  void _log(String c) {
    calls.add(c);
    onCall?.call(c);
  }

  @override
  Future<int> context() async {
    _log('context');
    if (contextFails) throw StateError('offline');
    return generation;
  }

  @override
  Future<SeedStepUpBegin> stepUpBegin({
    required String installId,
    required String keyId,
    required Map<String, String> publicJwk,
  }) async {
    _log('stepUpBegin');
    if (stepUpFails) throw StateError('offline');
    lastJwk = publicJwk;
    return const SeedStepUpBegin('tok1', 'options');
  }

  @override
  Future<SeedEnrollChallenge> enrollBegin({
    required String installId,
    required String keyId,
    required Map<String, String> publicJwk,
    required Object assertion,
    required String token,
  }) async {
    _log('enrollBegin');
    if (enrollBeginFails || committed) throw StateError('409');
    return SeedEnrollChallenge(
      token: 'tok2',
      ownerId: challengeOwner,
      keyId: challengeKey,
      installId: challengeInstall,
      generation: challengeGeneration ?? generation,
      challenge: 'C' * 43,
      actionDigest: actionDigest,
      expiresAt: 1800000100000,
    );
  }

  @override
  Future<bool> enrollFinish({
    required String signature,
    required String token,
  }) async {
    _log('finish');
    if (finishThrows) {
      if (commitBeforeThrow) committed = true;
      throw StateError('lost response');
    }
    if (finishCommits) committed = true;
    return finishCommits;
  }

  @override
  Future<SeedServerKeyState> keyStatus({
    required String owner,
    required String keyId,
  }) async {
    _log('status');
    if (statusThrows) throw StateError('offline');
    return status;
  }
}

class FakePasskey implements SeedPasskeyAsserter {
  int count = 0;
  bool cancel = false;
  @override
  Future<Object> assertStepUp(Object options) async {
    count++;
    if (cancel) throw StateError('cancelled');
    return 'assertion';
  }
}

void main() {
  late FakeNative native;
  late FakeApi api;
  late FakePasskey passkey;
  late bool current;
  SeedEnrollmentCoordinator build() => SeedEnrollmentCoordinator(
    native: native,
    api: api,
    passkey: passkey,
    isCurrent: (o) async => current && o == 'owner',
  );
  Future<SeedEnrollResult> run([SeedEnrollmentCoordinator? c]) =>
      (c ?? build()).run(owner: 'owner', installId: _install);
  int count(List<String> l, String c) => l.where((x) => x == c).length;

  setUp(() {
    native = FakeNative();
    api = FakeApi();
    passkey = FakePasskey();
    current = true;
  });

  test('happy path order, JWK shape and confirmation', () async {
    final r = await run();
    expect(r.outcome, SeedEnrollOutcome.confirmed);
    expect(r.keyId, _key);
    expect(api.calls, [
      'context',
      'context',
      'stepUpBegin',
      'enrollBegin',
      'finish',
    ]);
    expect(native.calls.where((c) => c != 'journal'), [
      'prepare',
      'sign',
      'confirm',
    ]);
    expect(native.stored!.phase, SeedEnrollmentPhase.confirmed);
    expect(api.lastJwk!.keys.toList(), ['kty', 'crv', 'x', 'y']);
    expect(api.lastJwk!['kty'], 'EC');
    expect(api.lastJwk!['x']!.length, 43);
  });

  test('confirmed journal needs no network or native change', () async {
    await run();
    api.calls.clear();
    native.calls.clear();
    final r = await run(build());
    expect(r.outcome, SeedEnrollOutcome.alreadyConfirmed);
    expect(api.calls, isEmpty);
    expect(native.calls, ['journal']);
  });

  test('offline context before prepare changes nothing', () async {
    api.contextFails = true;
    final r = await run();
    expect(r.outcome, SeedEnrollOutcome.serverUnavailable);
    expect(native.stored, isNull);
    expect(native.calls, ['journal']);
  });

  group('restart at each journal phase', () {
    test(
      'prepared: new coordinator resumes the same key, no second prepare',
      () async {
        api.stepUpFails = true;
        expect((await run()).outcome, SeedEnrollOutcome.serverUnavailable);
        expect(native.stored!.phase, SeedEnrollmentPhase.prepared);
        api.stepUpFails = false;
        native.calls.clear();
        final r = await run(build());
        expect(r.outcome, SeedEnrollOutcome.confirmed);
        expect(r.keyId, _key);
        expect(native.calls.contains('prepare'), false);
      },
    );

    test('signed, lost finish, never committed: resumes the SAME key with a fresh challenge', () async {
      api.finishThrows = true;
      expect((await run()).outcome, SeedEnrollOutcome.pendingServerOutcome);
      expect(native.stored!.phase, SeedEnrollmentPhase.signed);
      final digestBefore = native.stored!.actionDigest;
      api.finishThrows = false;
      api.calls.clear();
      native.calls.clear();
      final r = await run(build());
      expect(r.outcome, SeedEnrollOutcome.confirmed);
      expect(r.keyId, _key);
      expect(api.calls.first, 'status');
      expect(count(api.calls, 'finish'), 1);
      expect(count(native.calls, 'prepare'), 0);
      expect(count(native.calls, 'sign'), 1);
      expect(passkey.count, 2);
      expect(native.stored!.keyId, _key);
      expect(native.stored!.actionDigest, digestBefore);
      expect(native.stored!.phase, SeedEnrollmentPhase.confirmed);
    });

    test('signed, lost finish that DID commit: opaque status never makes a second key, active confirms', () async {
      api.finishThrows = true;
      api.commitBeforeThrow = true;
      await run();
      expect(api.committed, true);
      api.calls.clear();
      native.calls.clear();
      // status is opaque (transient); the server refuses a key id that exists
      final r = await run(build());
      expect(r.outcome, SeedEnrollOutcome.pendingServerOutcome);
      expect(api.calls.contains('finish'), false);
      expect(native.calls.contains('sign'), false);
      expect(native.stored!.phase, SeedEnrollmentPhase.signed);
      api.status = SeedServerKeyState.active;
      final c = await run(build());
      expect(c.outcome, SeedEnrollOutcome.confirmed);
      expect(count(api.calls, 'finish'), 0);
      expect(count(native.calls, 'prepare'), 0);
    });

    test('signed, resume is refused when the generation moved: preserved for the fenced reset', () async {
      api.finishThrows = true;
      await run();
      api.finishThrows = false;
      api.generation = 9;
      api.calls.clear();
      final r = await run(build());
      expect(r.outcome, SeedEnrollOutcome.staleGeneration);
      expect(api.calls, ['status', 'context']);
      expect(native.stored!.phase, SeedEnrollmentPhase.signed);
      expect(native.stored!.generation, 3);
    });

    test(
      'signed, resume where native refuses the server digest: nothing finished',
      () async {
        api.finishThrows = true;
        await run();
        api.finishThrows = false;
        native.refuseDigest = true;
        api.calls.clear();
        expect((await run(build())).outcome, SeedEnrollOutcome.actionMismatch);
        expect(api.calls.contains('finish'), false);
        expect(native.stored!.phase, SeedEnrollmentPhase.signed);
      },
    );

    test(
      'signed, resume while offline stays signed and sends nothing',
      () async {
        api.finishThrows = true;
        await run();
        api.statusThrows = true;
        api.calls.clear();
        expect(
          (await run(build())).outcome,
          SeedEnrollOutcome.pendingServerOutcome,
        );
        expect(api.calls, ['status']);
      },
    );

    test('signed then status active confirms through native', () async {
      api.finishThrows = true;
      await run();
      api.status = SeedServerKeyState.active;
      final r = await run(build());
      expect(r.outcome, SeedEnrollOutcome.confirmed);
      expect(native.stored!.phase, SeedEnrollmentPhase.confirmed);
      expect(count(api.calls, 'finish'), 1);
      expect(passkey.count, 1);
    });

    test(
      'signed then status revoked or generation change preserves state',
      () async {
        api.finishThrows = true;
        await run();
        api.status = SeedServerKeyState.revoked;
        expect(
          (await run(build())).outcome,
          SeedEnrollOutcome.revokedUnconfirmed,
        );
        api.status = SeedServerKeyState.generationChanged;
        expect(
          (await run(build())).outcome,
          SeedEnrollOutcome.generationChangedUnconfirmed,
        );
        expect(native.stored!.phase, SeedEnrollmentPhase.signed);
        expect(count(native.calls, 'prepare'), 1);
      },
    );

    test('status failure and opaque status stay pending', () async {
      api.finishThrows = true;
      await run();
      api.statusThrows = true;
      expect(
        (await run(build())).outcome,
        SeedEnrollOutcome.pendingServerOutcome,
      );
      expect(native.calls.contains('confirm'), false);
    });

    test('status active but native cannot confirm stays pending', () async {
      api.finishThrows = true;
      await run();
      api.status = SeedServerKeyState.active;
      native.confirmFail = SeedSyncFailureKind.unknownOutcome;
      expect(
        (await run(build())).outcome,
        SeedEnrollOutcome.pendingServerOutcome,
      );
      expect(native.stored!.phase, SeedEnrollmentPhase.signed);
      native.confirmFail = null;
      expect((await run(build())).outcome, SeedEnrollOutcome.confirmed);
    });
  });

  group('lost responses', () {
    test('finish says not committed: unknown, never retried', () async {
      api.finishCommits = false;
      expect((await run()).outcome, SeedEnrollOutcome.pendingServerOutcome);
      expect(count(api.calls, 'finish'), 1);
      expect(native.calls.contains('confirm'), false);
    });

    test('native sign reply lost after journaling: no finish; next run signs the same key again', () async {
      native.signFail = SeedSyncFailureKind.unknownOutcome;
      native.signLandsBeforeFail = true;
      final r = await run();
      expect(r.outcome, SeedEnrollOutcome.pendingServerOutcome);
      expect(api.calls.contains('finish'), false);
      expect(native.stored!.phase, SeedEnrollmentPhase.signed);
      native.signFail = null;
      api.calls.clear();
      final again = await run(build());
      expect(again.outcome, SeedEnrollOutcome.confirmed);
      expect(again.keyId, _key);
      expect(count(native.calls, 'sign'), 2);
      expect(count(native.calls, 'prepare'), 1);
      expect(count(api.calls, 'finish'), 1);
    });

    test(
      'prepare reply lost but key created: continues from journal, one prepare',
      () async {
        native.prepareFail = SeedSyncFailureKind.unknownOutcome;
        native.prepareLandsBeforeFail = true;
        final r = await run();
        expect(r.outcome, SeedEnrollOutcome.confirmed);
        expect(count(native.calls, 'prepare'), 1);
      },
    );

    test('prepare lost and nothing created: no retry', () async {
      native.prepareFail = SeedSyncFailureKind.unknownOutcome;
      final r = await run();
      expect(r.outcome, SeedEnrollOutcome.nativeUnavailable);
      expect(count(native.calls, 'prepare'), 1);
      expect(native.stored, isNull);
    });

    test('enroll-begin failure before sign leaves prepared key', () async {
      api.enrollBeginFails = true;
      expect((await run()).outcome, SeedEnrollOutcome.serverUnavailable);
      expect(native.stored!.phase, SeedEnrollmentPhase.prepared);
      expect(native.calls.contains('sign'), false);
    });

    test('passkey cancel is recoverable and does not sign', () async {
      passkey.cancel = true;
      expect((await run()).outcome, SeedEnrollOutcome.serverUnavailable);
      expect(api.calls.contains('enrollBegin'), false);
      expect(native.stored!.phase, SeedEnrollmentPhase.prepared);
    });
  });

  group('stale generation and mismatches', () {
    test(
      'generation moved since prepare: preserved, nothing spent or replaced',
      () async {
        api.stepUpFails = true;
        await run();
        api.stepUpFails = false;
        api.generation = 4;
        api.calls.clear();
        native.calls.clear();
        final r = await run(build());
        expect(r.outcome, SeedEnrollOutcome.staleGeneration);
        expect(api.calls, ['context']);
        expect(passkey.count, 0);
        expect(native.calls, ['journal']);
        expect(native.stored!.generation, 3);
        expect(native.stored!.keyId, _key);
        // never recovers by itself: still stale on the next run
        expect((await run(build())).outcome, SeedEnrollOutcome.staleGeneration);
        expect(count(native.calls, 'prepare'), 0);
      },
    );

    test(
      'server challenge for another generation is refused before signing',
      () async {
        api.challengeGeneration = 9;
        expect((await run()).outcome, SeedEnrollOutcome.challengeMismatch);
        expect(native.calls.contains('sign'), false);
        expect(api.calls.contains('finish'), false);
      },
    );

    test('challenge for another key, owner or install is refused', () async {
      api.challengeKey = 'e' * 32;
      expect((await run()).outcome, SeedEnrollOutcome.challengeMismatch);
      api.challengeKey = _key;
      api.challengeOwner = 'other';
      expect((await run(build())).outcome, SeedEnrollOutcome.challengeMismatch);
      api.challengeOwner = 'owner';
      api.challengeInstall = 'J' * 43;
      expect((await run(build())).outcome, SeedEnrollOutcome.challengeMismatch);
      expect(native.calls.contains('sign'), false);
      expect(native.stored!.phase, SeedEnrollmentPhase.prepared);
    });

    test(
      'native refuses a server action digest: nothing signed or finished',
      () async {
        native.refuseDigest = true;
        final r = await run();
        expect(r.outcome, SeedEnrollOutcome.actionMismatch);
        expect(api.calls.contains('finish'), false);
        expect(native.stored!.phase, SeedEnrollmentPhase.prepared);
        expect(native.stored!.actionDigest, isNull);
      },
    );

    test(
      'install id different from the journal is refused without network',
      () async {
        api.stepUpFails = true;
        await run();
        api.calls.clear();
        final r = await build().run(owner: 'owner', installId: 'K' * 43);
        expect(r.outcome, SeedEnrollOutcome.installMismatch);
        expect(api.calls, isEmpty);
      },
    );
  });

  group('account switch and disable', () {
    test('not current at start: no network, no native mutation', () async {
      current = false;
      expect((await run()).outcome, SeedEnrollOutcome.notCurrent);
      expect(api.calls, isEmpty);
      expect(native.calls, ['journal']);
    });

    test('different owner is never enrolled', () async {
      final r = await build().run(owner: 'someone-else', installId: _install);
      expect(r.outcome, SeedEnrollOutcome.notCurrent);
      expect(native.stored, isNull);
    });

    test('lost after prepare, before step-up: nothing spent', () async {
      api.onCall = (c) {
        if (c == 'context') current = false;
      };
      expect((await run()).outcome, SeedEnrollOutcome.notCurrent);
      expect(passkey.count, 0);
      expect(native.stored, isNull);
    });

    test('lost after the passkey: enroll-begin and sign are not used', () async {
      api.onCall = (c) {
        if (c == 'stepUpBegin') current = false;
      };
      // context is called twice on a fresh run: first creates, second validates
      api.stepUpFails = false;
      expect((await run()).outcome, SeedEnrollOutcome.notCurrent);
      expect(api.calls.contains('enrollBegin'), false);
      expect(native.calls.contains('sign'), false);
    });

    test('lost between begin and sign: no signature', () async {
      api.onCall = (c) {
        if (c == 'enrollBegin') current = false;
      };
      expect((await run()).outcome, SeedEnrollOutcome.notCurrent);
      expect(native.calls.contains('sign'), false);
    });

    test('lost after sign: finish is not sent, journal stays signed', () async {
      final c = SeedEnrollmentCoordinator(
        native: native,
        api: api,
        passkey: passkey,
        isCurrent: (o) async => !native.calls.contains('sign'),
      );
      final r = await run(c);
      expect(r.outcome, SeedEnrollOutcome.notCurrent);
      expect(api.calls.contains('finish'), false);
      expect(native.stored!.phase, SeedEnrollmentPhase.signed);
    });

    test('guard that throws counts as not current', () async {
      final c = SeedEnrollmentCoordinator(
        native: native,
        api: api,
        passkey: passkey,
        isCurrent: (o) async => throw StateError('x'),
      );
      expect((await run(c)).outcome, SeedEnrollOutcome.notCurrent);
    });
  });

  test('concurrent callers share one run: one passkey, one finish', () async {
    final c = build();
    final rs = await Future.wait([run(c), run(c), run(c)]);
    expect(rs.map((r) => r.outcome), everyElement(SeedEnrollOutcome.confirmed));
    expect(passkey.count, 1);
    expect(count(api.calls, 'finish'), 1);
  });

  test('native read failure is non-mutating', () async {
    final c = SeedEnrollmentCoordinator(
      native: _Throwing(),
      api: api,
      passkey: passkey,
      isCurrent: (_) async => true,
    );
    expect((await run(c)).outcome, SeedEnrollOutcome.nativeUnavailable);
    expect(api.calls, isEmpty);
  });

  test('seedPublicJwk rejects non-uncompressed points', () {
    expect(() => seedPublicJwk(Uint8List(65)), throwsArgumentError);
    expect(() => seedPublicJwk(Uint8List(33)), throwsArgumentError);
  });
}

class _Throwing extends FakeNative {
  @override
  Future<SeedEnrollmentJournal?> journal(String owner) async =>
      throw const SeedSyncFailure(SeedSyncFailureKind.metadataUnavailable);
}
