import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

Matcher guardFails(GuardError e) =>
    throwsA(isA<GuardException>().having((x) => x.error, 'error', e));

const o = 'owner1', d = 'dev1';

GuardSnapshot snap(
  Map<String, int> v, {
  int revision = 1,
  bool complete = true,
  int epoch = 0,
  Map<String, int> tombstones = const {},
  String owner = o,
  String device = d,
}) => GuardSnapshot(
  ownerId: owner,
  deviceId: device,
  epoch: epoch,
  revision: revision,
  complete: complete,
  versions: v,
  tombstones: tombstones,
);

ProvisionTicket issue(NativeSeedSyncGuard g, String e, int v) =>
    g.issue(ownerId: o, deviceId: d, entryId: e, seedVersion: v);

void use(
  NativeSeedSyncGuard g,
  ProvisionTicket t, {
  String owner = o,
  String device = d,
  int epoch = 0,
  String? entry,
  int? version,
}) => g.consume(
  t,
  ownerId: owner,
  deviceId: device,
  epoch: epoch,
  entryId: entry ?? t.entryId,
  seedVersion: version ?? t.seedVersion,
);

NativeSeedSyncGuard fresh() =>
    NativeSeedSyncGuard(ownerId: o, deviceId: d, epoch: 0);

void main() {
  test(
    'not ready until a complete snapshot; a partial one does not ready it',
    () {
      final g = fresh();
      expect(() => issue(g, 'a', 1), guardFails(GuardError.notReady));
      g.applySnapshot(snap({'a': 1}, complete: false));
      expect(g.ready, isFalse);
      expect(() => issue(g, 'a', 1), guardFails(GuardError.notReady));
      g.applySnapshot(snap({'a': 1}, revision: 2));
      expect(g.ready, isTrue);
      use(g, issue(g, 'a', 1));
    },
  );

  test('happy path: ticket is single use', () {
    final g = fresh()..applySnapshot(snap({'a': 3}));
    final t = issue(g, 'a', 3);
    use(g, t);
    expect(() => use(g, t), guardFails(GuardError.staleTicket));
  });

  test('only the authorized version can be issued; unlisted and wrong versions fail', () {
    final g = fresh()..applySnapshot(snap({'a': 3}));
    expect(() => issue(g, 'a', 2), guardFails(GuardError.unauthorized));
    expect(() => issue(g, 'a', 4), guardFails(GuardError.unauthorized));
    expect(() => issue(g, 'zz', 1), guardFails(GuardError.unauthorized));
  });

  test('absent-local complete-omission race: complete snapshot omits the entry while a request is in flight', () {
    final g = fresh()..applySnapshot(snap({'a': 1, 'b': 1}));
    final t = issue(g, 'b', 1); // request sent
    g.applySnapshot(snap({'a': 1}, revision: 2)); // b omitted
    expect(() => use(g, t), guardFails(GuardError.staleTicket));
    expect(() => issue(g, 'b', 1), guardFails(GuardError.unauthorized));
  });

  test('a partial snapshot never authorizes unlisted entries, but invalidates tickets', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final t = issue(g, 'a', 1);
    g.applySnapshot(snap({'c': 5}, revision: 2, complete: false));
    expect(() => use(g, t), guardFails(GuardError.staleTicket));
    expect(() => issue(g, 'x', 1), guardFails(GuardError.unauthorized));
    expect(g.authorizedVersion('a'), 1);
    issue(g, 'c', 5);
  });

  test('tombstone in a partial snapshot removes authorization and floors the version', () {
    final g = fresh()..applySnapshot(snap({'a': 2}));
    g.applySnapshot(
      snap({}, revision: 2, complete: false, tombstones: {'a': 2}),
    );
    expect(() => issue(g, 'a', 2), guardFails(GuardError.unauthorized));
    g.applySnapshot(snap({'a': 3}, revision: 3, complete: false));
    issue(g, 'a', 3);
    // A later listing at an old version cannot re-authorize below the tombstone.
    g.applySnapshot(
      snap({}, revision: 4, complete: false, tombstones: {'a': 3}),
    );
    expect(() => issue(g, 'a', 3), guardFails(GuardError.unauthorized));
  });

  test(
    'out-of-order and replayed snapshots are rejected and change nothing',
    () {
      final g = fresh()..applySnapshot(snap({'a': 1}, revision: 5));
      final t = issue(g, 'a', 1);
      for (final r in [5, 4, 1]) {
        expect(
          () => g.applySnapshot(snap({}, revision: r)),
          guardFails(GuardError.staleSnapshot),
        );
      }
      use(g, t); // ticket still good
    },
  );

  test('out-of-order seed responses: the older ticket dies when a newer snapshot lands', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final old = issue(g, 'a', 1);
    g.applySnapshot(snap({'a': 2}, revision: 2)); // rotation
    final fresh2 = issue(g, 'a', 2);
    expect(() => use(g, old), guardFails(GuardError.staleTicket));
    use(g, fresh2);
  });

  test('rotation: a response carrying the superseded version is refused even with a valid-looking ticket', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final t = issue(g, 'a', 1);
    g.applySnapshot(snap({'a': 2}, revision: 2));
    expect(() => use(g, t, version: 1), guardFails(GuardError.staleTicket));
    final t2 = issue(g, 'a', 2);
    expect(() => use(g, t2, version: 1), guardFails(GuardError.unauthorized));
  });

  test('response claims must match the ticket: entry, version, owner, device, epoch', () {
    final g = fresh()..applySnapshot(snap({'a': 1, 'b': 1}));
    for (final bad in <void Function(ProvisionTicket)>[
      (t) => use(g, t, entry: 'b'),
      (t) => use(g, t, version: 2),
      (t) => use(g, t, owner: 'other'),
      (t) => use(g, t, device: 'other'),
      (t) => use(g, t, epoch: 1),
    ]) {
      final t = issue(g, 'a', 1);
      expect(() => bad(t), throwsA(isA<GuardException>()));
    }
    // A mismatch does not consume a good ticket by itself being wrong.
    final t = issue(g, 'a', 1);
    use(g, t);
  });

  test('forged ticket with the same fields is refused', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final other = fresh()..applySnapshot(snap({'a': 1}));
    final foreign = issue(other, 'a', 1);
    expect(() => use(g, foreign), guardFails(GuardError.staleTicket));
  });

  test('stale or foreign epoch: snapshots and responses; a server epoch never advances it', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    expect(
      () => g.applySnapshot(snap({}, revision: 2, epoch: 1)),
      guardFails(GuardError.epochMismatch),
    );
    expect(
      () => g.applySnapshot(snap({}, revision: 3, epoch: 99)),
      guardFails(GuardError.epochMismatch),
    );
    expect(g.epoch, 0);
    final t = issue(g, 'a', 1);
    expect(() => use(g, t, epoch: 1), guardFails(GuardError.epochMismatch));
  });

  test('owner and device mismatch on snapshot and issue', () {
    final g = fresh();
    expect(
      () => g.applySnapshot(snap({}, owner: 'x')),
      guardFails(GuardError.ownerMismatch),
    );
    expect(
      () => g.applySnapshot(snap({}, device: 'x')),
      guardFails(GuardError.deviceMismatch),
    );
    g.applySnapshot(snap({'a': 1}));
    expect(
      () => g.issue(ownerId: 'x', deviceId: d, entryId: 'a', seedVersion: 1),
      guardFails(GuardError.ownerMismatch),
    );
    expect(
      () => g.issue(ownerId: o, deviceId: 'x', entryId: 'a', seedVersion: 1),
      guardFails(GuardError.deviceMismatch),
    );
  });

  test('disable kills in-flight tickets and refuses all later work until explicit enable and a new complete snapshot', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final t = issue(g, 'a', 1);
    g.disable();
    expect(() => use(g, t), guardFails(GuardError.staleTicket));
    expect(() => issue(g, 'a', 1), guardFails(GuardError.disabled));
    expect(
      () => g.applySnapshot(snap({'a': 1}, revision: 9, epoch: 1)),
      guardFails(GuardError.disabled),
    );
    expect(() => g.enable(-1), throwsA(isA<GuardException>()));
    g.enable(1);
    expect(g.ready, isFalse);
    expect(() => issue(g, 'a', 1), guardFails(GuardError.notReady));
    g.applySnapshot(snap({'a': 1}, revision: 1, epoch: 1));
    use(g, issue(g, 'a', 1), epoch: 1);
  });

  test('enable cannot go below the current epoch', () {
    final g = NativeSeedSyncGuard(ownerId: o, deviceId: d, epoch: 3);
    g.disable();
    expect(() => g.enable(2), guardFails(GuardError.epochMismatch));
  });

  test('owner switch invalidates tickets and old-owner snapshots', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final t = issue(g, 'a', 1);
    g.switchOwner(ownerId: 'owner2', deviceId: d, epoch: 0);
    expect(() => use(g, t), guardFails(GuardError.staleTicket));
    expect(
      () => g.applySnapshot(snap({'a': 1}, revision: 2)),
      guardFails(GuardError.ownerMismatch),
    );
    expect(
      () =>
          g.issue(ownerId: 'owner2', deviceId: d, entryId: 'a', seedVersion: 1),
      guardFails(GuardError.notReady),
    );
    g.applySnapshot(snap({'a': 1}, owner: 'owner2'));
    g.issue(ownerId: 'owner2', deviceId: d, entryId: 'a', seedVersion: 1);
  });

  test('restart without durable state: tickets dead, not ready, a complete snapshot (even lower revision) restores', () {
    final g = fresh()..applySnapshot(snap({'a': 1}, revision: 8));
    final t = issue(g, 'a', 1);
    g.restart();
    expect(() => use(g, t), guardFails(GuardError.staleTicket));
    expect(() => issue(g, 'a', 1), guardFails(GuardError.notReady));
    g.applySnapshot(snap({'a': 1}, complete: false, revision: 9));
    expect(g.ready, isFalse, reason: 'partial cannot restore');
    g.applySnapshot(snap({'a': 1}, revision: 10));
    use(g, issue(g, 'a', 1));
  });

  test('contradictory and invalid snapshots are refused whole', () {
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final t = issue(g, 'a', 1);
    for (final bad in [
      snap({'a': 2}, revision: 2, tombstones: {'a': 2}),
      snap({'': 1}, revision: 2),
      snap({'a': 0}, revision: 2),
      snap({'a': custodyMaxSafeInt + 1}, revision: 2),
      snap({}, revision: 0),
      snap({}, revision: custodyMaxSafeInt + 1),
      snap({}, revision: 2, tombstones: {'a': -1}),
    ]) {
      expect(
        () => g.applySnapshot(bad),
        guardFails(GuardError.invalidSnapshot),
      );
    }
    use(g, t); // nothing changed, ticket still valid
    expect(g.authorizedVersion('a'), 1);
  });

  test('invalid constructor and issue inputs', () {
    expect(
      () => NativeSeedSyncGuard(ownerId: '', deviceId: d, epoch: 0),
      guardFails(GuardError.invalidInput),
    );
    expect(
      () => NativeSeedSyncGuard(ownerId: o, deviceId: d, epoch: -1),
      guardFails(GuardError.invalidInput),
    );
    final g = fresh()..applySnapshot(snap({'a': 1}));
    expect(() => issue(g, 'a', 0), guardFails(GuardError.invalidInput));
    expect(() => issue(g, '', 1), guardFails(GuardError.invalidInput));
  });

  test('guard plus fake custody transport model: a rejected response never reaches custody', () async {
    // Models the integration: consume then provision, serialized by the caller.
    final g = fresh()..applySnapshot(snap({'a': 1}));
    final provisioned = <String>[];
    Future<void> deliver(ProvisionTicket t, int version) async {
      try {
        use(g, t, version: version);
      } on GuardException {
        return; // caller zeroes the seed; custody is never called
      }
      provisioned.add('${t.entryId}@$version');
    }

    final t1 = issue(g, 'a', 1);
    g.applySnapshot(snap({}, revision: 2)); // a removed while in flight
    await deliver(t1, 1);
    g.applySnapshot(snap({'a': 2}, revision: 3));
    final t2 = issue(g, 'a', 2);
    await deliver(t2, 2);
    await deliver(t2, 2); // duplicate delivery
    expect(provisioned, ['a@2']);
  });
}
