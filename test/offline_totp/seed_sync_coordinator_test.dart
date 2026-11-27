import 'dart:async';
import 'dart:typed_data';

import 'fake_seed_custody.dart';

import 'package:otpanda_client/offline_totp/otp_account.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/native_seed_custody.dart';
import 'package:otpanda_client/offline_totp/seed_sync_channel.dart';
import 'package:otpanda_client/offline_totp/seed_sync_coordinator.dart';
import 'package:otpanda_client/offline_totp/seed_sync_http.dart';

final keyId = 'a' * 32;
final install = 'I' * 22;
final point = [4, ...List.filled(64, 7)];
final eph = 'E' * 87;
const scope = SeedSyncScope(
  owner: 'owner',
  installId: 'IIIIIIIIIIIIIIIIIIIIII',
  epoch: 4,
);

SeedSyncChallenge chal({
  String owner = 'owner',
  String device = 'dev',
  int generation = 2,
  bool batch = false,
}) => SeedSyncChallenge(
  token: 'otpda_${'T' * 55}',
  ownerId: owner,
  keyId: keyId,
  deviceId: device,
  generation: generation,
  epoch: 4,
  challenge: 'A' * 43,
  expiresAt: 1800000120000,
);

SeedSyncSnapshotEntry se(String id, int v) =>
    SeedSyncSnapshotEntry(id, v, 'SHA-1', 6, 30);

SeedSyncSnapshot snap(
  List<SeedSyncSnapshotEntry> e, {
  int revision = 9,
  bool complete = true,
  int maxBatch = 3,
  Map<String, int> tomb = const {},
  Map<String, String> unsup = const {},
}) => SeedSyncSnapshot(
  ownerId: 'owner',
  deviceId: 'dev',
  epoch: 4,
  challengeDigest: sha256HexOf('A' * 43),
  revision: revision,
  complete: complete,
  maxBatch: maxBatch,
  entries: e,
  unsupported: unsup,
  tombstones: tomb,
);

SeedSyncBatchResult sealed(String id, int v) => SeedSyncBatchResult(
  entryId: id,
  status: SeedSyncResultStatus.sealed,
  seedVersion: v,
  algorithm: 'SHA-1',
  digits: 6,
  period: 30,
  nonce: 'N$id',
  ciphertext: 'C$id',
);

class Log {
  final events = <String>[];
  void add(String e) => events.add(e);
}

class FakeCustody implements NativeSeedCustody {
  FakeCustody(this.log);
  final Log log;
  CustodyOwnerState state = const CustodyOwnerState(epoch: 4, enabled: true);
  Object? reconcileError;
  List<String> need = [];
  List<String> pending = [];
  CustodySnapshot? applied;
  @override
  Future<CustodyOwnerState> readOwnerState(String ownerId) async => state;
  @override
  Future<ReconcileResult> reconcile(
    String ownerId,
    CustodySnapshot snapshot,
  ) async {
    log.add('reconcile');
    applied = snapshot;
    if (reconcileError != null) throw reconcileError!;
    return ReconcileResult(
      removed: const ['gone'],
      needsProvision: need,
      pendingPurge: pending,
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) {
    log.add('FORBIDDEN custody ${i.memberName}');
    throw UnimplementedError();
  }
}

class FakeNative implements SeedSyncNative {
  FakeNative(this.log);
  final Log log;
  SeedEnrollmentJournal? j;
  Object? journalError, beginError, openError, bindError, signError, proofError;
  int handles = 0;
  final failOpen = <String>{};
  final opened = <String>[];
  @override
  Future<SeedEnrollmentJournal?> journal(String owner) async {
    if (journalError != null) throw journalError!;
    return j;
  }

  @override
  Future<String> snapshotProof({
    required String owner,
    required String keyId,
    required String deviceId,
    required int generation,
    required int epoch,
    required String challenge,
    required int expiresAt,
  }) async {
    log.add('proof $deviceId g$generation e$epoch');
    if (proofError != null) throw proofError!;
    return 'S' * 86;
  }

  @override
  Future<SeedBatchStart> begin({
    required String owner,
    required String deviceId,
    required int generation,
    required int epoch,
    required List<SeedBatchEntry> entries,
  }) async {
    log.add(
      'begin ${entries.map((e) => '${e.entryId}@${e.seedVersion}').join(',')}',
    );
    if (beginError != null) throw beginError!;
    return SeedBatchStart(
      '${'h'}${(++handles).toString().padLeft(31, '0')}',
      eph,
    );
  }

  @override
  Future<void> bind(
    String handleId, {
    required String challenge,
    required int expiresAt,
  }) async {
    log.add('bind');
    if (bindError != null) throw bindError!;
  }

  @override
  Future<String> signBatch(String handleId) async {
    log.add('sign');
    if (signError != null) throw signError!;
    return 'S' * 86;
  }

  @override
  Future<List<String>> open(
    String handleId, {
    required String entryId,
    required String serverPublicKey,
    required String nonce,
    required String ciphertext,
  }) async {
    log.add('open $entryId $serverPublicKey $nonce $ciphertext');
    if (failOpen.contains(entryId)) throw openError!;
    opened.add(entryId);
    return const [];
  }

  @override
  Future<List<String>> skip(String handleId, String entryId) async {
    log.add('skip $entryId');
    return const [];
  }

  @override
  Future<void> finish(String handleId) async => log.add('finish');
}

// Uses the stateful custody contract rather than a fixed needs list. Crypto is
// deliberately a seam here; the installed Android channel fixture separately
// covers the real sealed open and durable same-statement identity.
class StatefulNative extends FakeNative {
  StatefulNative(super.log, this.custody);
  final FakeSeedCustody custody;
  final wanted = <String, SeedBatchEntry>{};
  bool interruptB = true;
  @override
  Future<SeedBatchStart> begin({
    required String owner,
    required String deviceId,
    required int generation,
    required int epoch,
    required List<SeedBatchEntry> entries,
  }) {
    wanted.addEntries(entries.map((e) => MapEntry(e.entryId, e)));
    return super.begin(
      owner: owner,
      deviceId: deviceId,
      generation: generation,
      epoch: epoch,
      entries: entries,
    );
  }

  @override
  Future<List<String>> open(
    String handleId, {
    required String entryId,
    required String serverPublicKey,
    required String nonce,
    required String ciphertext,
  }) async {
    if (entryId == 'b' && interruptB) {
      throw StateError('simulated interrupted native reply');
    }
    final e = wanted[entryId]!;
    await custody.provision(
      ownerId: 'owner',
      entryId: entryId,
      seedVersion: e.seedVersion,
      algorithm: OtpAlgorithm.sha1,
      digits: e.digits,
      period: e.periodSeconds,
      seed: Uint8List.fromList(List.filled(20, 42)),
      epoch: 4,
    );
    opened.add(entryId);
    return const [];
  }
}

class FakeApi implements SeedSyncPullApi {
  FakeApi(this.log);
  final Log log;
  SeedSyncChallenge snapChallenge = chal();
  SeedSyncSnapshot snapshot = snap([se('a', 5)]);
  Object? snapBeginError, snapFinishError, batchBeginError, batchFinishError;
  final batchChallenge = <SeedSyncChallenge>[];
  SeedSyncChallenge? Function(List<({String entryId, int seedVersion})>)?
  batchChallengeFor;
  SeedSyncBatch Function(SeedSyncChallenge, List<SeedSyncBatchResult>)? shape;
  List<SeedSyncBatchResult> Function(List<({String entryId, int seedVersion})>)
  answer = (e) => [for (final x in e) sealed(x.entryId, x.seedVersion)];
  final requested = <List<({String entryId, int seedVersion})>>[];
  Future<void>? gate;
  void Function(String)? onCall;
  @override
  Future<SeedSyncChallenge> snapshotBegin({
    required String keyId,
    required int epoch,
  }) async {
    log.add('snapshot-begin');
    onCall?.call('snapshot-begin');
    if (gate != null) await gate;
    if (snapBeginError != null) throw snapBeginError!;
    return snapChallenge;
  }

  @override
  Future<SeedSyncSnapshot> snapshotFinish({
    required SeedSyncChallenge challenge,
    required String signature,
  }) async {
    log.add('snapshot-finish');
    onCall?.call('snapshot-finish');
    if (snapFinishError != null) throw snapFinishError!;
    return snapshot;
  }

  @override
  Future<SeedSyncChallenge> batchBegin({
    required String keyId,
    required int epoch,
    required String ephemeralKey,
    required List<({String entryId, int seedVersion})> entries,
  }) async {
    log.add('batch-begin');
    onCall?.call('batch-begin');
    requested.add(entries);
    if (batchBeginError != null) throw batchBeginError!;
    return chal();
  }

  @override
  Future<SeedSyncBatch> batchFinish({
    required SeedSyncChallenge challenge,
    required String signature,
  }) async {
    log.add('batch-finish');
    onCall?.call('batch-finish');
    if (batchFinishError != null) throw batchFinishError!;
    final results = answer(requested.last);
    return SeedSyncBatch(
      ownerId: 'owner',
      deviceId: 'dev',
      epoch: 4,
      challengeDigest: sha256HexOf('A' * 43),
      serverPublicKey:
          results.any((r) => r.status == SeedSyncResultStatus.sealed)
          ? 'K' * 87
          : null,
      results: results,
    );
  }
}

SeedEnrollmentJournal journal({
  SeedEnrollmentPhase phase = SeedEnrollmentPhase.confirmed,
  String key = '',
  int generation = 2,
  String inst = 'IIIIIIIIIIIIIIIIIIIIII',
}) => SeedEnrollmentJournal(
  key.isEmpty ? keyId : key,
  Uint8List.fromList(point),
  inst,
  generation,
  phase,
  phase == SeedEnrollmentPhase.prepared ? null : 'd' * 64,
);

class Rig {
  Rig() {
    custody = FakeCustody(log);
    native = FakeNative(log)..j = journal();
    api = FakeApi(log);
    c = SeedSyncCoordinator(
      api: api,
      native: native,
      custody: custody,
      current: (o) async => signedIn,
    );
  }
  final log = Log();
  late FakeCustody custody;
  late FakeNative native;
  late FakeApi api;
  late SeedSyncCoordinator c;
  bool signedIn = true;
  List<String> get ev => log.events;
  Future<SeedSyncResult> run([SeedSyncScope s = scope]) => c.sync(s);
}

bool noForbidden(Rig r) => !r.ev.any((e) => e.startsWith('FORBIDDEN'));

void main() {
  test('interrupted pull replays exact snapshot and pulls only remaining custody need', () async {
    final log = Log(), custody = FakeSeedCustody();
    await custody.enableOwner('owner', epoch: 4);
    final native = StatefulNative(log, custody)..j = journal();
    final api = FakeApi(log)..snapshot = snap([se('a', 5), se('b', 8)]);
    SeedSyncCoordinator coordinator() => SeedSyncCoordinator(
      api: api,
      native: native,
      custody: custody,
      current: (_) async => true,
    );
    expect(
      (await coordinator().sync(scope)).outcome,
      SeedSyncOutcome.unknownOutcome,
    );
    expect(custody.versionOf('owner', 'a'), 5);
    expect(custody.versionOf('owner', 'b'), isNull);
    native.interruptB = false;
    // A new coordinator simulates lost orchestration state, retaining custody.
    expect((await coordinator().sync(scope)).outcome, SeedSyncOutcome.synced);
    expect(api.requested.map((b) => b.map((e) => e.entryId).toList()), [
      ['a', 'b'],
      ['b'],
    ]);
    expect(native.opened, ['a', 'b']);
    api.snapshot = snap([se('a', 6), se('b', 8)]);
    expect(
      (await coordinator().sync(scope)).outcome,
      SeedSyncOutcome.staleSnapshot,
    );
    expect(api.requested.length, 2);
  });
  test(
    'happy path: snapshot, reconcile, then one signed batch; native opens',
    () async {
      final r = Rig();
      r.custody.need = ['b', 'a'];
      r.api.snapshot = snap([se('a', 5), se('b', 8)]);
      final res = await r.run();
      expect(res.outcome, SeedSyncOutcome.synced);
      expect(r.ev, [
        'snapshot-begin',
        'proof dev g2 e4',
        'snapshot-finish',
        'reconcile',
        'begin a@5,b@8',
        'batch-begin',
        'bind',
        'sign',
        'batch-finish',
        'open a ${'K' * 87} Na Ca',
        'open b ${'K' * 87} Nb Cb',
        'finish',
      ]);
      expect(res.entries.map((e) => e.state), [
        SeedSyncEntryState.provisioned,
        SeedSyncEntryState.provisioned,
      ]);
      expect(res.removed, ['gone']);
      expect(res.revision, 9);
      expect(r.custody.applied!.versions, {'a': 5, 'b': 8});
      expect(r.custody.applied!.epoch, 4);
      expect(r.custody.applied!.complete, isTrue);
      expect(noForbidden(r), isTrue);
    },
  );

  test('only entries custody needs are pulled, in batches of at most maxBatch, each with a fresh handle', () async {
    final r = Rig();
    r.custody.need = ['e', 'a', 'd', 'b'];
    r.api.snapshot = snap([
      for (final i in 'abcde'.split('')) se(i, 3),
    ], maxBatch: 2);
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.synced);
    expect(r.api.requested.map((b) => b.map((e) => e.entryId).toList()), [
      ['a', 'b'],
      ['d', 'e'],
    ]);
    expect(r.native.opened, ['a', 'b', 'd', 'e']);
    expect(r.ev.where((e) => e == 'finish').length, 2);
    expect(r.ev.indexOf('reconcile'), lessThan(r.ev.indexOf('begin a@3,b@3')));
    expect(r.ev.where((e) => e == 'snapshot-begin').length, 1);
  });

  test('maxBatch above the native limit never exceeds three', () async {
    final r = Rig();
    r.custody.need = ['a', 'b', 'c', 'd'];
    r.api.snapshot = snap([for (final i in 'abcd'.split('')) se(i, 3)]);
    await r.run();
    expect(r.api.requested.map((b) => b.length), [3, 1]);
  });

  test('nothing needed: no batch, synced', () async {
    final r = Rig();
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.synced);
    expect(r.ev, [
      'snapshot-begin',
      'proof dev g2 e4',
      'snapshot-finish',
      'reconcile',
    ]);
  });

  test(
    'unsupported ids go to custody as preserve, complete stays true',
    () async {
      final r = Rig();
      r.api.snapshot = snap(
        [se('a', 9)],
        unsup: {'u': 'unsupported', 'm': 'metadata_pending'},
      );
      await r.run();
      expect(r.custody.applied!.complete, isTrue);
      expect(r.custody.applied!.preserve, {'u', 'm'});
      expect(r.custody.applied!.versions.keys, ['a']);
    },
  );

  test('tombstones and complete=false reach custody unchanged', () async {
    final r = Rig();
    r.api.snapshot = snap([se('a', 9)], complete: false, tomb: {'x': 4});
    await r.run();
    expect(r.custody.applied!.complete, isFalse);
    expect(r.custody.applied!.tombstones, {'x': 4});
  });

  test('server skips (stale, removed, unsupported) are consumed natively, never opened, and leave partial', () async {
    final r = Rig();
    r.custody.need = ['a', 'b', 'c'];
    r.api.snapshot = snap([se('a', 5), se('b', 5), se('c', 5)]);
    r.api.answer = (e) => [
      SeedSyncBatchResult(
        entryId: 'a',
        status: SeedSyncResultStatus.stale,
        seedVersion: 6,
      ),
      SeedSyncBatchResult(entryId: 'b', status: SeedSyncResultStatus.removed),
      SeedSyncBatchResult(
        entryId: 'c',
        status: SeedSyncResultStatus.unsupported,
      ),
    ];
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.partial);
    expect(r.native.opened, isEmpty);
    expect(r.ev.where((e) => e.startsWith('skip')).toList(), [
      'skip a',
      'skip b',
      'skip c',
    ]);
    expect(res.entries.map((e) => e.state).toSet(), {
      SeedSyncEntryState.skipped,
    });
  });

  test('needed entry the snapshot does not list as supported is reported, not pulled', () async {
    final r = Rig();
    r.custody.need = ['a', 'ghost'];
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.partial);
    expect(res.unprovisionable, ['ghost']);
    expect(r.api.requested.single.map((e) => e.entryId), ['a']);
  });

  test(
    'pending physical delete keeps the run partial and is reported',
    () async {
      final r = Rig();
      r.custody.pending = ['owner/x'];
      final res = await r.run();
      expect(res.outcome, SeedSyncOutcome.partial);
      expect(res.pendingPurge, ['owner/x']);
    },
  );

  test('revision 0: custody is not touched and nothing is pulled', () async {
    final r = Rig();
    r.api.snapshot = snap([], revision: 0);
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.emptyOwner);
    expect(r.ev.contains('reconcile'), isFalse);
    r.api.snapshot = snap([se('a', 1)], revision: 0);
    final bad = await r.run();
    expect(bad.outcome, SeedSyncOutcome.serverMalformed);
    expect(r.ev.contains('reconcile'), isFalse);
  });

  test('enrollment must be confirmed, for this install: otherwise no network at all', () async {
    for (final (j, expected) in <(SeedEnrollmentJournal?, SeedSyncOutcome)>[
      (null, SeedSyncOutcome.notEnrolled),
      (
        journal(phase: SeedEnrollmentPhase.prepared),
        SeedSyncOutcome.notEnrolled,
      ),
      (journal(phase: SeedEnrollmentPhase.signed), SeedSyncOutcome.notEnrolled),
      (journal(inst: 'J' * 22), SeedSyncOutcome.installMismatch),
    ]) {
      final r = Rig()..native.j = j;
      expect((await r.run()).outcome, expected);
      expect(r.ev, isEmpty);
    }
  });

  test('not signed in, opted out, or another epoch: nothing sent', () async {
    var r = Rig()..signedIn = false;
    expect((await r.run()).outcome, SeedSyncOutcome.notCurrent);
    expect(r.ev, isEmpty);
    r = Rig()
      ..custody.state = const CustodyOwnerState(epoch: 4, enabled: false);
    expect((await r.run()).outcome, SeedSyncOutcome.notCurrent);
    r = Rig()..custody.state = const CustodyOwnerState(epoch: 5, enabled: true);
    expect((await r.run()).outcome, SeedSyncOutcome.notCurrent);
    expect(r.ev, isEmpty);
  });

  test('unreadable native state is nativeUnavailable, never absence', () async {
    final r = Rig()..native.journalError = StateError('x');
    expect((await r.run()).outcome, SeedSyncOutcome.nativeUnavailable);
    expect(r.ev, isEmpty);
  });

  test('sign-out or opt-out between steps stops before the next network or native step', () async {
    for (final (after, last) in [
      ('snapshot-begin', 'snapshot-begin'),
      ('snapshot-finish', 'snapshot-finish'),
    ]) {
      final r = Rig();
      r.api.onCall = (c) {
        if (c == after) r.signedIn = false;
      };
      final res = await r.run();
      expect(res.outcome, SeedSyncOutcome.notCurrent);
      expect(
        r.ev.last == last || r.ev.last.startsWith('proof'),
        isTrue,
        reason: r.ev.toString(),
      );
      expect(r.ev.contains('reconcile'), isFalse);
    }
    var r = Rig()..custody.need = ['a'];
    r.api.onCall = (c) {
      if (c == 'batch-finish') r.signedIn = false;
    };
    var res = await r.run();
    expect(res.outcome, SeedSyncOutcome.notCurrent);
    expect(r.native.opened, isEmpty);
    expect(r.ev.last, 'finish');
    expect(res.entries.single.state, SeedSyncEntryState.notAttempted);
    r = Rig()..custody.need = ['a'];
    r.api.onCall = (c) {
      if (c == 'batch-begin') r.signedIn = false;
    };
    res = await r.run();
    expect(res.outcome, SeedSyncOutcome.notCurrent);
    expect(r.ev.contains('bind'), isFalse);
    expect(r.ev.contains('batch-finish'), isFalse);
  });

  test(
    'enrollment replaced mid-run (new key id or generation) stops the run',
    () async {
      final r = Rig()..custody.need = ['a'];
      r.api.onCall = (c) {
        if (c == 'batch-begin') r.native.j = journal(key: 'b' * 32);
      };
      expect((await r.run()).outcome, SeedSyncOutcome.notCurrent);
      expect(r.native.opened, isEmpty);
      final g = Rig()..custody.need = ['a'];
      g.api.onCall = (c) {
        if (c == 'snapshot-finish') g.native.j = journal(generation: 3);
      };
      expect((await g.run()).outcome, SeedSyncOutcome.notCurrent);
      expect(g.ev.contains('reconcile'), isFalse);
    },
  );

  test('server challenge for another owner, generation or device is refused before native signs', () async {
    for (final c in [chal(owner: 'other'), chal(generation: 3)]) {
      final r = Rig()..api.snapChallenge = c;
      expect((await r.run()).outcome, SeedSyncOutcome.challengeMismatch);
      expect(r.ev, ['snapshot-begin']);
    }
    final r = Rig()..api.snapChallenge = chal(device: 'other');
    final res = await r.run(
      const SeedSyncScope(
        owner: 'owner',
        installId: 'IIIIIIIIIIIIIIIIIIIIII',
        epoch: 4,
        deviceId: 'dev',
      ),
    );
    expect(res.outcome, SeedSyncOutcome.challengeMismatch);
    expect(r.ev, ['snapshot-begin']);
  });

  test(
    'verified key-revoked and generation-changed are reported, never acted on',
    () async {
      for (final (e, o) in [
        (
          const SeedSyncSignedStateException(SeedSyncSignedState.keyRevoked),
          SeedSyncOutcome.keyRevoked,
        ),
        (
          const SeedSyncSignedStateException(
            SeedSyncSignedState.generationChanged,
          ),
          SeedSyncOutcome.generationChanged,
        ),
      ]) {
        final r = Rig()..api.snapFinishError = e;
        final res = await r.run();
        expect(res.outcome, o);
        expect(r.ev.contains('reconcile'), isFalse);
        expect(noForbidden(r), isTrue);
      }
      final r = Rig()..custody.need = ['a'];
      r.api.batchFinishError = const SeedSyncSignedStateException(
        SeedSyncSignedState.keyRevoked,
      );
      final res = await r.run();
      expect(res.outcome, SeedSyncOutcome.keyRevoked);
      expect(r.native.opened, isEmpty);
      expect(r.ev.last, 'finish');
      expect(noForbidden(r), isTrue);
    },
  );

  test('server unavailable or malformed at each step: no reconcile before a snapshot, no open without an answer', () async {
    var r = Rig()
      ..api.snapBeginError = const SeedSyncPullException(
        SeedSyncPullFailure.unavailable,
      );
    expect((await r.run()).outcome, SeedSyncOutcome.serverUnavailable);
    r = Rig()
      ..api.snapFinishError = const SeedSyncPullException(
        SeedSyncPullFailure.shape,
      );
    expect((await r.run()).outcome, SeedSyncOutcome.serverMalformed);
    expect(r.ev.contains('reconcile'), isFalse);
    r = Rig()..api.snapFinishError = TimeoutException('t');
    expect((await r.run()).outcome, SeedSyncOutcome.serverUnavailable);
    r = Rig()..custody.need = ['a', 'b'];
    r.api.snapshot = snap([se('a', 1), se('b', 1)]);
    r.api.batchFinishError = const SeedSyncPullException(
      SeedSyncPullFailure.unavailable,
    );
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.serverUnavailable);
    expect(r.native.opened, isEmpty);
    expect(
      r.ev.where((e) => e == 'batch-finish').length,
      1,
      reason: 'no retry',
    );
    expect(res.entries.map((e) => e.state), [
      SeedSyncEntryState.notAttempted,
      SeedSyncEntryState.notAttempted,
    ]);
    expect(r.ev.last, 'finish');
  });

  test('a failed batch stops the run: later batches are not started', () async {
    final r = Rig()..custody.need = ['a', 'b'];
    r.api.snapshot = snap([se('a', 1), se('b', 1)], maxBatch: 1);
    r.api.batchBeginError = const SeedSyncPullException(
      SeedSyncPullFailure.unavailable,
    );
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.serverUnavailable);
    expect(r.ev.where((e) => e == 'batch-begin').length, 1);
    expect(res.entries.map((e) => e.state), [
      SeedSyncEntryState.notAttempted,
      SeedSyncEntryState.notAttempted,
    ]);
  });

  test(
    'batch answers that do not match the request are refused before any open',
    () async {
      final cases =
          <
            String,
            List<SeedSyncBatchResult> Function(
              List<({String entryId, int seedVersion})>,
            )
          >{
            'missing entry': (e) => [sealed('a', 5)],
            'extra entry': (e) => [
              sealed('a', 5),
              sealed('b', 5),
              sealed('zz', 1),
            ],
            'unrequested entry': (e) => [sealed('a', 5), sealed('zz', 1)],
            'version changed': (e) => [sealed('a', 6), sealed('b', 5)],
            'metadata changed': (e) => [
              SeedSyncBatchResult(
                entryId: 'a',
                status: SeedSyncResultStatus.sealed,
                seedVersion: 5,
                algorithm: 'SHA-256',
                digits: 6,
                period: 30,
                nonce: 'n',
                ciphertext: 'c',
              ),
              sealed('b', 5),
            ],
          };
      for (final c in cases.entries) {
        final r = Rig()..custody.need = ['a', 'b'];
        r.api.snapshot = snap([se('a', 5), se('b', 5)]);
        r.api.answer = c.value;
        final res = await r.run();
        expect(res.outcome, SeedSyncOutcome.serverMalformed, reason: c.key);
        expect(r.native.opened, isEmpty, reason: c.key);
        expect(r.ev.last, 'finish');
      }
    },
  );

  test('native open failure is an unknown outcome: stop, no replay, no later entry opened', () async {
    final r = Rig()..custody.need = ['a', 'b'];
    r.api.snapshot = snap([se('a', 5), se('b', 5)]);
    r.native.failOpen.add('a');
    r.native.openError = const SeedSyncFailure(
      SeedSyncFailureKind.unknownOutcome,
    );
    final res = await r.run();
    expect(res.outcome, SeedSyncOutcome.unknownOutcome);
    expect(r.native.opened, isEmpty);
    expect(res.entries.map((e) => (e.entryId, e.state)), [
      ('a', SeedSyncEntryState.failed),
      ('b', SeedSyncEntryState.notAttempted),
    ]);
    expect(r.ev.where((e) => e.startsWith('open')).length, 1);
    expect(r.ev.last, 'finish');
    final q = Rig()..custody.need = ['a'];
    q.native.failOpen.add('a');
    q.native.openError = const SeedSyncFailure(SeedSyncFailureKind.custody);
    final qr = await q.run();
    expect(qr.outcome, SeedSyncOutcome.nativeUnavailable);
    expect(qr.entries.single.failure, SeedSyncFailureKind.custody);
  });

  test('native begin, bind and sign failures stop the run and never reach finish with a signature', () async {
    var r = Rig()
      ..custody.need = ['a']
      ..native.beginError = const SeedSyncFailure(SeedSyncFailureKind.busy);
    var res = await r.run();
    expect(res.outcome, SeedSyncOutcome.nativeUnavailable);
    expect(r.ev.contains('batch-begin'), isFalse);
    r = Rig()
      ..custody.need = ['a']
      ..native.beginError = const SeedSyncFailure(
        SeedSyncFailureKind.unknownOutcome,
      );
    expect((await r.run()).outcome, SeedSyncOutcome.unknownOutcome);
    r = Rig()
      ..custody.need = ['a']
      ..native.signError = const SeedSyncFailure(SeedSyncFailureKind.wire);
    res = await r.run();
    expect(res.outcome, SeedSyncOutcome.unknownOutcome);
    expect(r.ev.contains('batch-finish'), isFalse);
    expect(r.ev.last, 'finish');
    r = Rig()
      ..native.proofError = const SeedSyncFailure(SeedSyncFailureKind.wire);
    expect((await r.run()).outcome, SeedSyncOutcome.nativeUnavailable);
    expect(r.ev.contains('snapshot-finish'), isFalse);
  });

  test('custody refusals: stale snapshot, invalid snapshot, disabled, unknown failure; no pull', () async {
    for (final (e, o) in <(Object, SeedSyncOutcome)>[
      (
        const CustodyException(CustodyError.staleSnapshot),
        SeedSyncOutcome.staleSnapshot,
      ),
      (
        const CustodyException(CustodyError.invalidSnapshot),
        SeedSyncOutcome.custodyRefused,
      ),
      (
        const CustodyException(CustodyError.disabled),
        SeedSyncOutcome.custodyRefused,
      ),
      (
        const CustodyException(CustodyError.epochMismatch),
        SeedSyncOutcome.custodyRefused,
      ),
      (
        const CustodyException(CustodyError.metadataUnavailable),
        SeedSyncOutcome.unknownOutcome,
      ),
      (StateError('x'), SeedSyncOutcome.unknownOutcome),
    ]) {
      final r = Rig()
        ..custody.need = ['a']
        ..custody.reconcileError = e;
      final res = await r.run();
      expect(res.outcome, o, reason: '$e');
      expect(r.ev.contains('begin a@5'), isFalse);
      expect(noForbidden(r), isTrue);
    }
  });

  test(
    'concurrent callers with the same scope share one run; another scope waits',
    () async {
      final r = Rig();
      final gate = Completer<void>();
      r.api.gate = gate.future;
      final a = r.run(), b = r.run();
      final other = r.run(
        const SeedSyncScope(
          owner: 'owner',
          installId: 'IIIIIIIIIIIIIIIIIIIIII',
          epoch: 4,
          deviceId: 'dev',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(r.ev.where((e) => e == 'snapshot-begin').length, 1);
      gate.complete();
      final results = await Future.wait([a, b, other]);
      expect(identical(results[0], results[1]), isTrue);
      expect(r.ev.where((e) => e == 'snapshot-begin').length, 2);
      expect(results[2].outcome, SeedSyncOutcome.synced);
    },
  );

  test(
    'sync never throws, even when a collaborator does something unexpected',
    () async {
      final r = Rig()..custody.need = ['a'];
      r.api.snapBeginError = 'not an exception type';
      expect((await r.run()).outcome, SeedSyncOutcome.serverUnavailable);
      final q = Rig()..custody.need = ['a'];
      q.api.answer = (e) => throw StateError('boom');
      expect((await q.run()).outcome, SeedSyncOutcome.serverUnavailable);
    },
  );
}
