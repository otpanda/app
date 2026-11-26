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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  const snapshot = GuardSnapshot(
    ownerId: 'o',
    deviceId: 'd',
    epoch: 0,
    revision: 1,
    complete: true,
    versions: {'e': 1},
  );
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
