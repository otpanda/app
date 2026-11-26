import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';
import 'package:otpanda_client/offline_totp/native_custody_sync.dart';

import 'fake_seed_custody.dart';

final class DelayedCustody implements NativeSeedCustody {
  final fake = FakeSeedCustody();
  final entered = Completer<void>(), proceed = Completer<void>();
  @override
  Future<void> provision({
    required String ownerId,
    required String entryId,
    required int seedVersion,
    required OtpAlgorithm algorithm,
    required int digits,
    required int period,
    required Uint8List seed,
    required int epoch,
  }) async {
    entered.complete();
    await proceed.future;
    await fake.provision(
      ownerId: ownerId,
      entryId: entryId,
      seedVersion: seedVersion,
      algorithm: algorithm,
      digits: digits,
      period: period,
      seed: seed,
      epoch: epoch,
    );
  }

  @override
  Future<ReconcileResult> reconcile(String ownerId, CustodySnapshot snapshot) =>
      fake.reconcile(ownerId, snapshot);
  @override
  Future<ClearOwnerResult> clearOwner(String ownerId, {required int epoch}) =>
      fake.clearOwner(ownerId, epoch: epoch);
  @override
  Future<PurgeOwnerResult> purgeOwner(String ownerId, {required int epoch}) =>
      fake.purgeOwner(ownerId, epoch: epoch);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test(
    'purge preserves default and optout, rejects future epoch without change',
    () async {
      final f = FakeSeedCustody();
      final first = await f.purgeOwner('o', epoch: 0);
      expect(first.epoch, 1);
      expect((await f.readOwnerState('o')).enabled, true);
      await expectLater(
        f.purgeOwner('o', epoch: 5),
        throwsA(isA<CustodyException>()),
      );
      await expectLater(
        f.clearOwner('o', epoch: 5),
        throwsA(isA<CustodyException>()),
      );
      expect((await f.readOwnerState('o')).epoch, 1);
      await f.clearOwner('o', epoch: 1);
      expect((await f.readOwnerState('o')).enabled, false);
      final older = await f.purgeOwner('o', epoch: 0);
      expect(older.epoch, 2);
      expect((await f.readOwnerState('o')).enabled, false);
      expect((await f.readCatalog('o')).entries, isEmpty);
      final sync = await NativeCustodySync.open(
        custody: f,
        ownerId: 'o',
        deviceId: 'd',
      );
      await sync.purge();
      expect((await f.readOwnerState('o')).enabled, false);
    },
  );
  test(
    'restart state keeps disabled owner disabled and guard unready',
    () async {
      final fake = FakeSeedCustody();
      final initial = await NativeCustodySync.open(
        custody: fake,
        ownerId: 'o',
        deviceId: 'd',
      );
      expect((await initial.readOwnerState()).enabled, true);
      await expectLater(
        initial.issue(
          ownerId: 'o',
          deviceId: 'd',
          entryId: 'e',
          seedVersion: 1,
        ),
        throwsA(isA<GuardException>()),
      );
      await initial.disable();
      final restarted = await NativeCustodySync.open(
        custody: fake,
        ownerId: 'o',
        deviceId: 'd',
      );
      final saved = await restarted.readOwnerState();
      expect(saved.epoch, 1);
      expect(saved.enabled, false);
      await expectLater(
        restarted.issue(
          ownerId: 'o',
          deviceId: 'd',
          entryId: 'e',
          seedVersion: 1,
        ),
        throwsA(isA<GuardException>()),
      );
      fake.metadataDown = true;
      await expectLater(
        NativeCustodySync.open(custody: fake, ownerId: 'o', deviceId: 'd'),
        throwsA(isA<CustodyException>()),
      );
    },
  );
  test(
    'owner switch reads destination opt-out and enable stays unready',
    () async {
      final fake = FakeSeedCustody();
      await fake.clearOwner('other', epoch: 0);
      final sync = await NativeCustodySync.open(
        custody: fake,
        ownerId: 'o',
        deviceId: 'd',
      );
      await sync.switchOwner(ownerId: 'other', deviceId: 'd2');
      expect((await sync.readOwnerState()).enabled, false);
      await expectLater(
        sync.issue(
          ownerId: 'other',
          deviceId: 'd2',
          entryId: 'e',
          seedVersion: 1,
        ),
        throwsA(
          isA<GuardException>().having(
            (e) => e.error,
            'error',
            GuardError.disabled,
          ),
        ),
      );
      await sync.enable(1);
      await expectLater(
        sync.issue(
          ownerId: 'other',
          deviceId: 'd2',
          entryId: 'e',
          seedVersion: 1,
        ),
        throwsA(
          isA<GuardException>().having(
            (e) => e.error,
            'error',
            GuardError.notReady,
          ),
        ),
      );
      await expectLater(
        sync.reconcile(
          const GuardSnapshot(
            ownerId: 'other',
            deviceId: 'd2',
            epoch: 2,
            revision: 1,
            complete: true,
            versions: {'e': 1},
          ),
        ),
        throwsA(
          isA<GuardException>().having(
            (e) => e.error,
            'error',
            GuardError.epochMismatch,
          ),
        ),
      );
      expect((await sync.readOwnerState()).epoch, 1);
    },
  );
  test('a durable state divergence invalidates active authorization', () async {
    final fake = FakeSeedCustody();
    final sync = await NativeCustodySync.open(
      custody: fake,
      ownerId: 'o',
      deviceId: 'd',
    );
    await sync.reconcile(
      const GuardSnapshot(
        ownerId: 'o',
        deviceId: 'd',
        epoch: 0,
        revision: 1,
        complete: true,
        versions: {'e': 1},
      ),
    );
    await fake.clearOwner('o', epoch: 0);
    expect((await sync.readOwnerState()).enabled, false);
    await expectLater(
      sync.issue(ownerId: 'o', deviceId: 'd', entryId: 'e', seedVersion: 1),
      throwsA(
        isA<GuardException>().having(
          (e) => e.error,
          'error',
          GuardError.disabled,
        ),
      ),
    );
  });
  const snapshot = GuardSnapshot(
    ownerId: 'o',
    deviceId: 'd',
    epoch: 0,
    revision: 1,
    complete: true,
    versions: {'e': 1},
  );
  for (final switching in [false, true]) {
    test(
      'lifecycle purge rejects old network seed after ${switching ? "switch" : "purge"}',
      () async {
        final fake = FakeSeedCustody();
        final sync = await NativeCustodySync.open(
          custody: fake,
          ownerId: 'o',
          deviceId: 'd',
        );
        await sync.reconcile(snapshot);
        final ticket = await sync.issue(
          ownerId: 'o',
          deviceId: 'd',
          entryId: 'e',
          seedVersion: 1,
        );
        if (switching) {
          await sync.switchOwner(ownerId: 'other', deviceId: 'd2');
        } else {
          await sync.purge();
        }
        final seed = Uint8List.fromList(List.filled(20, 1));
        await expectLater(
          sync.accept(
            ticket,
            ownerId: 'o',
            deviceId: 'd',
            epoch: 0,
            entryId: 'e',
            seedVersion: 1,
            algorithm: OtpAlgorithm.sha1,
            digits: 6,
            period: 30,
            seed: seed,
          ),
          throwsA(isA<GuardException>()),
        );
        expect(seed, everyElement(0));
        expect(fake.entries('o'), isEmpty);
        expect((await fake.readOwnerState('o')).enabled, true);
        final reopened = await NativeCustodySync.open(
          custody: fake,
          ownerId: 'o',
          deviceId: 'd',
        );
        await expectLater(
          reopened.issue(
            ownerId: 'o',
            deviceId: 'd',
            entryId: 'e',
            seedVersion: 1,
          ),
          throwsA(
            isA<GuardException>().having(
              (e) => e.error,
              'error',
              GuardError.notReady,
            ),
          ),
        );
      },
    );
  }
  test(
    'native ahead purge adopts effective epoch and stays disabled',
    () async {
      final fake = FakeSeedCustody();
      final sync = await NativeCustodySync.open(
        custody: fake,
        ownerId: 'o',
        deviceId: 'd',
      );
      await fake.purgeOwner('o', epoch: 0);
      await fake.purgeOwner('o', epoch: 1);
      expect((await sync.purge()).epoch, 2);
      await expectLater(
        sync.issue(ownerId: 'o', deviceId: 'd', entryId: 'e', seedVersion: 1),
        throwsA(
          isA<GuardException>().having(
            (e) => e.error,
            'error',
            GuardError.disabled,
          ),
        ),
      );
      await sync.enable(2);
      await expectLater(
        sync.issue(ownerId: 'o', deviceId: 'd', entryId: 'e', seedVersion: 1),
        throwsA(
          isA<GuardException>().having(
            (e) => e.error,
            'error',
            GuardError.notReady,
          ),
        ),
      );
    },
  );
  test('failed purge keeps owner and disabled guard', () async {
    final fake = FakeSeedCustody();
    final sync = await NativeCustodySync.open(
      custody: fake,
      ownerId: 'o',
      deviceId: 'd',
    );
    fake.metadataDown = true;
    await expectLater(
      sync.switchOwner(ownerId: 'other', deviceId: 'd2'),
      throwsA(isA<CustodyException>()),
    );
    fake.metadataDown = false;
    await expectLater(
      sync.issue(ownerId: 'o', deviceId: 'd', entryId: 'e', seedVersion: 1),
      throwsA(
        isA<GuardException>().having(
          (e) => e.error,
          'error',
          GuardError.disabled,
        ),
      ),
    );
    expect((await sync.readOwnerState()).epoch, 0);
  });
  test(
    'disable cannot interleave between guard consumption and custody provision',
    () async {
      final store = DelayedCustody();
      final sync = NativeCustodySync(
        custody: store,
        ownerId: 'o',
        deviceId: 'd',
        epoch: 0,
      );
      await sync.reconcile(snapshot);
      final ticket = await sync.issue(
        ownerId: 'o',
        deviceId: 'd',
        entryId: 'e',
        seedVersion: 1,
      );
      final seed = Uint8List.fromList(List.filled(20, 1));
      final accepting = sync.accept(
        ticket,
        ownerId: 'o',
        deviceId: 'd',
        epoch: 0,
        entryId: 'e',
        seedVersion: 1,
        algorithm: OtpAlgorithm.sha1,
        digits: 6,
        period: 30,
        seed: seed,
      );
      await store.entered.future;
      var cleared = false;
      final clearing = sync.disable().then((_) {
        cleared = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(cleared, false);
      store.proceed.complete();
      await accepting;
      await clearing;
      expect(seed, everyElement(0));
      expect(store.fake.entries('o'), isEmpty);
      await expectLater(
        store.fake.generate(
          ownerId: 'o',
          entryId: 'e',
          seedVersion: 1,
          unixSeconds: 59,
        ),
        throwsA(isA<CustodyException>()),
      );
    },
  );
  test(
    'purge cannot interleave between guard consumption and custody provision',
    () async {
      final store = DelayedCustody();
      final sync = NativeCustodySync(
        custody: store,
        ownerId: 'o',
        deviceId: 'd',
        epoch: 0,
      );
      await sync.reconcile(snapshot);
      final ticket = await sync.issue(
        ownerId: 'o',
        deviceId: 'd',
        entryId: 'e',
        seedVersion: 1,
      );
      final seed = Uint8List.fromList(List.filled(20, 1));
      final accepting = sync.accept(
        ticket,
        ownerId: 'o',
        deviceId: 'd',
        epoch: 0,
        entryId: 'e',
        seedVersion: 1,
        algorithm: OtpAlgorithm.sha1,
        digits: 6,
        period: 30,
        seed: seed,
      );
      await store.entered.future;
      var cleared = false;
      final clearing = sync.purge().then((_) {
        cleared = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(cleared, false);
      store.proceed.complete();
      await accepting;
      await clearing;
      expect(seed, everyElement(0));
      expect(store.fake.entries('o'), isEmpty);
      await expectLater(
        store.fake.generate(
          ownerId: 'o',
          entryId: 'e',
          seedVersion: 1,
          unixSeconds: 59,
        ),
        throwsA(isA<CustodyException>()),
      );
    },
  );
  test('owner switch cannot interleave between guard consumption and custody provision', () async {
    final store = DelayedCustody();
    final sync = NativeCustodySync(
      custody: store,
      ownerId: 'o',
      deviceId: 'd',
      epoch: 0,
    );
    await sync.reconcile(snapshot);
    final ticket = await sync.issue(
      ownerId: 'o',
      deviceId: 'd',
      entryId: 'e',
      seedVersion: 1,
    );
    final seed = Uint8List.fromList(List.filled(20, 1));
    final accepting = sync.accept(
      ticket,
      ownerId: 'o',
      deviceId: 'd',
      epoch: 0,
      entryId: 'e',
      seedVersion: 1,
      algorithm: OtpAlgorithm.sha1,
      digits: 6,
      period: 30,
      seed: seed,
    );
    await store.entered.future;
    var cleared = false;
    final clearing = sync.switchOwner(ownerId: 'other', deviceId: 'd2').then((
      _,
    ) {
      cleared = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(cleared, false);
    store.proceed.complete();
    await accepting;
    await clearing;
    expect(seed, everyElement(0));
    expect(store.fake.entries('o'), isEmpty);
    await expectLater(
      store.fake.generate(
        ownerId: 'o',
        entryId: 'e',
        seedVersion: 1,
        unixSeconds: 59,
      ),
      throwsA(isA<CustodyException>()),
    );
  });
  test(
    'disable before response rejects stale seed and queue remains usable',
    () async {
      final fake = FakeSeedCustody();
      final sync = NativeCustodySync(
        custody: fake,
        ownerId: 'o',
        deviceId: 'd',
        epoch: 0,
      );
      await sync.reconcile(snapshot);
      final ticket = await sync.issue(
        ownerId: 'o',
        deviceId: 'd',
        entryId: 'e',
        seedVersion: 1,
      );
      await sync.disable();
      final seed = Uint8List.fromList(List.filled(20, 1));
      await expectLater(
        sync.accept(
          ticket,
          ownerId: 'o',
          deviceId: 'd',
          epoch: 0,
          entryId: 'e',
          seedVersion: 1,
          algorithm: OtpAlgorithm.sha1,
          digits: 6,
          period: 30,
          seed: seed,
        ),
        throwsA(isA<GuardException>()),
      );
      expect(seed, everyElement(0));
      expect(fake.entries('o'), isEmpty);
      await sync.enable(1);
      await sync.reconcile(
        const GuardSnapshot(
          ownerId: 'o',
          deviceId: 'd',
          epoch: 1,
          revision: 2,
          complete: true,
          versions: {'e': 2},
        ),
      );
      await sync.issue(
        ownerId: 'o',
        deviceId: 'd',
        entryId: 'e',
        seedVersion: 2,
      );
    },
  );
}
