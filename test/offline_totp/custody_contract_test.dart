// Contract tests for NativeSeedCustody using an in-memory fake. The fake gives
// no confidentiality and says nothing about any real OS store or hardware.
// Seeds are the published RFC 6238 test keys.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

import 'fake_seed_custody.dart';

Uint8List ascii(String s) => Uint8List.fromList(utf8.encode(s));
final k1 = ascii('12345678901234567890');
final k256 = ascii('12345678901234567890123456789012');
final k512 = ascii(
  '1234567890123456789012345678901234567890123456789012345678901234',
);

Matcher custodyFails(CustodyError e) =>
    throwsA(isA<CustodyException>().having((x) => x.error, 'error', e));

Future<void> prov(
  FakeSeedCustody c, {
  String owner = 'o1',
  String entry = 'e1',
  int version = 1,
  OtpAlgorithm algo = OtpAlgorithm.sha1,
  int digits = 8,
  int period = 30,
  Uint8List? seed,
  int epoch = 0,
}) => c.provision(
  ownerId: owner,
  entryId: entry,
  seedVersion: version,
  algorithm: algo,
  digits: digits,
  period: period,
  seed: seed ?? k1,
  epoch: epoch,
);

Future<String> gen(
  FakeSeedCustody c, {
  String owner = 'o1',
  String entry = 'e1',
  int version = 1,
  int t = 59,
}) => c.generate(
  ownerId: owner,
  entryId: entry,
  seedVersion: version,
  unixSeconds: t,
);

void main() {
  group('reference calculator (RFC 6238)', () {
    String code(Uint8List k, OtpAlgorithm a, int d, int t, [int p = 30]) =>
        computeTotp(
          seed: k,
          algorithm: a,
          digits: d,
          period: p,
          unixSeconds: t,
        );
    test('published vectors, 6/7/8 digits, three digests, time past 2038', () {
      expect(code(k1, OtpAlgorithm.sha1, 8, 59), '94287082');
      expect(code(k1, OtpAlgorithm.sha1, 7, 59), '4287082');
      expect(code(k1, OtpAlgorithm.sha1, 6, 59), '287082');
      expect(code(k256, OtpAlgorithm.sha256, 8, 59), '46119246');
      expect(code(k512, OtpAlgorithm.sha512, 8, 59), '90693936');
      expect(code(k1, OtpAlgorithm.sha1, 8, 20000000000), '65353130');
      expect(code(k1, OtpAlgorithm.sha1, 8, 1111111109), '07081804');
    });
    test('period boundaries and range checks', () {
      expect(
        code(k1, OtpAlgorithm.sha1, 8, 29),
        code(k1, OtpAlgorithm.sha1, 8, 0),
      );
      expect(
        code(k1, OtpAlgorithm.sha1, 8, 30) ==
            code(k1, OtpAlgorithm.sha1, 8, 29),
        isFalse,
      );
      expect(
        code(k1, OtpAlgorithm.sha1, 8, 86399, 86400),
        code(k1, OtpAlgorithm.sha1, 8, 0, 86400),
      );
      expect(() => code(k1, OtpAlgorithm.sha1, 5, 0), throwsRangeError);
      expect(() => code(k1, OtpAlgorithm.sha1, 9, 0), throwsRangeError);
      expect(() => code(k1, OtpAlgorithm.sha1, 8, 0, 0), throwsRangeError);
      expect(() => code(k1, OtpAlgorithm.sha1, 8, 0, 86401), throwsRangeError);
      expect(() => code(k1, OtpAlgorithm.sha1, 8, -1), throwsRangeError);
    });
  });

  group('capability and fail-closed store states', () {
    test(
      'capability reports the protection and the reason when unavailable',
      () async {
        final c = FakeSeedCustody();
        expect(
          (await c.capability()).protection,
          CustodyProtection.osEncrypted,
        );
        c.unavailable = true;
        final cap = await c.capability();
        expect(cap.protection, CustodyProtection.unavailable);
        expect(cap.reason, isNotEmpty);
      },
    );

    test(
      'unavailable, locked and missing-key stores store and return nothing',
      () async {
        final c = FakeSeedCustody();
        await prov(c);
        c.unavailable = true;
        await expectLater(
          prov(c, entry: 'e2'),
          custodyFails(CustodyError.unavailable),
        );
        await expectLater(gen(c), custodyFails(CustodyError.unavailable));
        c.unavailable = false;
        c.locked = true;
        await expectLater(gen(c), custodyFails(CustodyError.locked));
        await expectLater(
          prov(c, entry: 'e2'),
          custodyFails(CustodyError.locked),
        );
        c.locked = false;
        expect(c.entries('o1'), [
          'e1',
        ], reason: 'failed provisions left nothing');
        c.loseKey();
        await expectLater(gen(c), custodyFails(CustodyError.missingKey));
        await expectLater(
          prov(c, entry: 'e3'),
          custodyFails(CustodyError.missingKey),
        );
      },
    );
  });

  group('provision and generate', () {
    test(
      'code comes from the stored parameters and only the code is returned',
      () async {
        final c = FakeSeedCustody();
        await prov(c);
        expect(await gen(c), '94287082');
        await prov(c, entry: 'e2', algo: OtpAlgorithm.sha256, seed: k256);
        expect(await gen(c, entry: 'e2'), '46119246');
        await prov(c, entry: 'e3', digits: 7, period: 86400);
        expect(
          await gen(c, entry: 'e3', t: 59),
          computeTotp(
            seed: k1,
            algorithm: OtpAlgorithm.sha1,
            digits: 7,
            period: 86400,
            unixSeconds: 0,
          ),
        );
      },
    );

    test('a provisioned buffer is copied; changing the caller copy changes nothing', () async {
      final c = FakeSeedCustody();
      final s = Uint8List.fromList(k1);
      await prov(c, seed: s);
      s.fillRange(0, s.length, 0);
      expect(await gen(c), '94287082');
    });

    test('invalid input is refused before anything is stored', () async {
      final c = FakeSeedCustody();
      for (final bad in <Future<void> Function()>[
        () => prov(c, owner: ''),
        () => prov(c, entry: 'a\nb'),
        () => prov(c, entry: 'x' * 129),
        () => prov(c, version: 0),
        () => prov(c, digits: 5),
        () => prov(c, digits: 9),
        () => prov(c, period: 0),
        () => prov(c, period: 86401),
        () => prov(c, seed: Uint8List(9)),
        () => prov(c, seed: Uint8List(129)),
      ]) {
        await expectLater(bad(), custodyFails(CustodyError.invalidInput));
      }
      expect(c.entries('o1'), isEmpty);
      await prov(c, period: 86400);
    });

    test('no overwrite without a newer version; an old response cannot replace a new seed', () async {
      final c = FakeSeedCustody();
      await prov(c, version: 2);
      await expectLater(
        prov(c, version: 2, seed: k256),
        custodyFails(CustodyError.versionConflict),
      );
      await expectLater(
        prov(c, version: 1, seed: k256),
        custodyFails(CustodyError.versionConflict),
      );
      expect(await gen(c, version: 2), '94287082');
      await prov(c, version: 3, seed: k256, algo: OtpAlgorithm.sha256);
      expect(await gen(c, version: 3), '46119246');
      await expectLater(
        gen(c, version: 2),
        custodyFails(CustodyError.versionConflict),
      );
    });

    test(
      'wrong owner or unknown entry is not found, other owners are unaffected',
      () async {
        final c = FakeSeedCustody();
        await prov(c);
        await expectLater(
          gen(c, owner: 'o2'),
          custodyFails(CustodyError.notFound),
        );
        await expectLater(
          gen(c, entry: 'nope'),
          custodyFails(CustodyError.notFound),
        );
        await prov(c, owner: 'o2');
        expect(await gen(c, owner: 'o2'), '94287082');
      },
    );
  });

  group('tamper, swap and metadata binding', () {
    test(
      'changed seed, changed metadata and a swapped record all fail closed',
      () async {
        final c = FakeSeedCustody();
        await prov(c);
        await prov(c, entry: 'e2', seed: k256, algo: OtpAlgorithm.sha256);
        c.corrupt('o1', 'e1');
        await expectLater(gen(c), custodyFails(CustodyError.tamper));

        final d = FakeSeedCustody();
        await prov(d);
        d.rewritePeriod('o1', 'e1', 60);
        await expectLater(gen(d), custodyFails(CustodyError.tamper));

        final e = FakeSeedCustody();
        await prov(e);
        await prov(e, entry: 'e2', seed: k256, algo: OtpAlgorithm.sha256);
        e.moveRecord('o1', 'e1', 'e9');
        await expectLater(
          gen(e, entry: 'e9'),
          custodyFails(CustodyError.tamper),
        );
      },
    );

    test('AAD binds owner, entry, version, epoch and every parameter, unambiguously', () {
      Uint8List aad(
        String o,
        String e,
        int v,
        OtpAlgorithm a,
        int d,
        int p,
        int ep,
      ) => custodyAad(
        ownerId: o,
        entryId: e,
        seedVersion: v,
        algorithm: a,
        digits: d,
        period: p,
        epoch: ep,
      );
      final base = aad('o', 'e', 1, OtpAlgorithm.sha1, 6, 30, 0);
      final variants = [
        aad('x', 'e', 1, OtpAlgorithm.sha1, 6, 30, 0),
        aad('o', 'x', 1, OtpAlgorithm.sha1, 6, 30, 0),
        aad('o', 'e', 2, OtpAlgorithm.sha1, 6, 30, 0),
        aad('o', 'e', 1, OtpAlgorithm.sha256, 6, 30, 0),
        aad('o', 'e', 1, OtpAlgorithm.sha1, 7, 30, 0),
        aad('o', 'e', 1, OtpAlgorithm.sha1, 6, 60, 0),
        aad('o', 'e', 1, OtpAlgorithm.sha1, 6, 30, 1),
      ];
      for (final v in variants) {
        expect(v, isNot(base));
      }
      expect(
        aad('ab', 'c', 1, OtpAlgorithm.sha1, 6, 30, 0),
        isNot(aad('a', 'bc', 1, OtpAlgorithm.sha1, 6, 30, 0)),
      );
    });

    test('a lowered or raised stored epoch is detected', () async {
      final c = FakeSeedCustody();
      await c.enableOwner('o1', epoch: 3);
      await prov(c, epoch: 3);
      c.rewriteEpoch('o1', 'e1', 9);
      await expectLater(gen(c), custodyFails(CustodyError.tamper));
    });
  });

  group('delete and version floors', () {
    test('delete removes one entry; an in-flight older provision cannot resurrect it', () async {
      final c = FakeSeedCustody();
      await prov(c, version: 3);
      await prov(c, entry: 'e2');
      await c.delete('o1', 'e1', seedVersion: 3);
      await expectLater(gen(c), custodyFails(CustodyError.notFound));
      expect(await gen(c, entry: 'e2'), '94287082');
      await expectLater(
        prov(c, version: 3),
        custodyFails(CustodyError.versionConflict),
      );
      await expectLater(
        prov(c, version: 2),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, version: 4);
      expect(await gen(c, version: 4), '94287082');
    });

    test('versioned delete on an absent entry floors it: an in-flight first provision cannot resurrect', () async {
      final c = FakeSeedCustody();
      await c.delete('o1', 'e1', seedVersion: 4);
      await expectLater(
        prov(c, version: 4),
        custodyFails(CustodyError.versionConflict),
      );
      await expectLater(
        prov(c, version: 1),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, version: 5);
      expect(await gen(c, version: 5), '94287082');
    });

    test('delete on a locked store denies at once and leaves the physical delete pending', () async {
      final c = FakeSeedCustody();
      await prov(c);
      c.locked = true;
      await c.delete('o1', 'e1', seedVersion: 1);
      await expectLater(gen(c), custodyFails(CustodyError.denied));
      expect(c.entries('o1'), [
        'e1',
      ], reason: 'still physically present, but unusable');
      expect(await c.purgePending(), ['o1/e1'], reason: 'still locked');
      c.locked = false;
      expect(await c.purgePending(), isEmpty);
      expect(c.entries('o1'), isEmpty);
    });
  });

  group('opt-out, enable and epochs', () {
    test('opt-out purges the owner and persists disabled; provision is refused until enableOwner', () async {
      final c = FakeSeedCustody();
      await c.enableOwner('o1', epoch: 4);
      await prov(c, epoch: 4);
      await prov(c, owner: 'o2', epoch: 0);
      final r = await c.clearOwner('o1', epoch: 4);
      expect((r.denied, r.purged), (true, true));
      expect(c.entries('o1'), isEmpty);
      for (final e in [2, 4, 5, 99]) {
        await expectLater(
          prov(c, entry: 'e9', epoch: e),
          custodyFails(CustodyError.disabled),
          reason: 'epoch $e cannot bypass the disabled flag',
        );
      }
      await expectLater(
        c.enableOwner('o1', epoch: 4),
        custodyFails(CustodyError.staleEpoch),
      );
      await c.enableOwner('o1', epoch: 5);
      await prov(c, entry: 'e9', epoch: 5);
      expect(await gen(c, entry: 'e9'), '94287082');
      expect(
        await gen(c, owner: 'o2'),
        '94287082',
        reason: 'other owner untouched',
      );
    });

    test('opt-out on a locked store denies immediately; the purge is pending, then completes', () async {
      final c = FakeSeedCustody();
      await c.enableOwner('o1', epoch: 2);
      await prov(c, epoch: 2);
      c.locked = true;
      final r = await c.clearOwner('o1', epoch: 2);
      expect((r.denied, r.purged), (true, false));
      await expectLater(gen(c), custodyFails(CustodyError.denied));
      await expectLater(
        prov(c, entry: 'e2', epoch: 3),
        custodyFails(CustodyError.disabled),
      );
      expect(c.entries('o1'), ['e1']);
      c.locked = false;
      expect(await c.purgePending(), isEmpty);
      expect(c.entries('o1'), isEmpty);
    });

    test(
      'same for an unavailable store, and a lost key still denies',
      () async {
        final c = FakeSeedCustody();
        await prov(c, epoch: 0);
        c.unavailable = true;
        expect((await c.clearOwner('o1', epoch: 0)).purged, isFalse);
        await expectLater(gen(c), custodyFails(CustodyError.denied));
        final d = FakeSeedCustody();
        await prov(d, epoch: 0);
        d.loseKey();
        final r = await d.clearOwner('o1', epoch: 0);
        expect(r.denied, isTrue);
        expect(d.entries('o1'), isEmpty, reason: 'delete needs no key');
        await expectLater(gen(d), custodyFails(CustodyError.notFound));
      },
    );

    test(
      'an OLD clear never denies, deletes or disables newer-epoch records',
      () async {
        final c = FakeSeedCustody();
        await prov(c, epoch: 0, version: 5);
        await c.clearOwner('o1', epoch: 0);
        await c.enableOwner('o1', epoch: 3);
        await prov(c, entry: 'n1', epoch: 3);
        // A delayed clear for epoch 1 arrives late.
        final r = await c.clearOwner('o1', epoch: 1);
        expect(r.purged, isTrue);
        expect(c.entries('o1'), ['n1']);
        expect(await gen(c, entry: 'n1'), '94287082');
        await prov(
          c,
          entry: 'n2',
          epoch: 3,
        ); // still enabled, epoch not lowered
        // Even on a locked store the old clear leaves the new record usable.
        c.locked = true;
        await c.clearOwner('o1', epoch: 2);
        c.locked = false;
        expect(await gen(c, entry: 'n1'), '94287082');
        expect(await c.purgePending(), isEmpty);
        expect(c.entries('o1')..sort(), ['n1', 'n2']);
      },
    );

    test(
      'a clear at the current epoch disables; a repeat does not re-enable',
      () async {
        final c = FakeSeedCustody();
        await c.enableOwner('o1', epoch: 1);
        await prov(c, epoch: 1);
        await c.clearOwner('o1', epoch: 1);
        await c.clearOwner('o1', epoch: 0);
        await expectLater(
          prov(c, epoch: 2),
          custodyFails(CustodyError.disabled),
        );
      },
    );

    test('enable at a newer epoch reuses the version; a response epoch above the local one is refused and changes nothing', () async {
      final c = FakeSeedCustody();
      await prov(c, epoch: 0, version: 5);
      await c.clearOwner('o1', epoch: 0);
      await c.enableOwner('o1', epoch: 1);
      await prov(c, epoch: 1, version: 5);
      expect(await gen(c, version: 5), '94287082');
      // A server response claiming epoch 2 cannot advance the local epoch.
      await expectLater(
        prov(c, entry: 'e2', epoch: 2),
        custodyFails(CustodyError.epochMismatch),
      );
      await expectLater(
        prov(c, entry: 'e2', epoch: 99),
        custodyFails(CustodyError.epochMismatch),
      );
      await expectLater(
        prov(c, entry: 'e3', epoch: 0),
        custodyFails(CustodyError.staleEpoch),
      );
      expect(
        await gen(c, version: 5),
        '94287082',
        reason: 'existing record untouched',
      );
      // Version floor history survived the refused attempts.
      await c.delete('o1', 'e1', seedVersion: 5);
      await expectLater(
        prov(c, version: 5, epoch: 1),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, version: 6, epoch: 1);
    });

    test(
      'a provision epoch above the local one is refused and never advances it',
      () async {
        final c = FakeSeedCustody();
        await prov(c, epoch: 0);
        await expectLater(
          prov(c, entry: 'e2', epoch: 5),
          custodyFails(CustodyError.epochMismatch),
        );
        c.locked = false;
        expect(await gen(c), '94287082');
        await prov(c, entry: 'e2', epoch: 0);
      },
    );

    test('a pending-purge record from an old epoch does not block a new-epoch provision', () async {
      final c = FakeSeedCustody();
      await prov(c, epoch: 0, version: 9);
      c.locked = true;
      await c.clearOwner('o1', epoch: 0);
      c.locked = false;
      await c.enableOwner('o1', epoch: 1);
      await prov(c, epoch: 1, version: 1);
      expect(await gen(c, version: 1), '94287082');
      await c.purgePending();
      expect(
        await gen(c, version: 1),
        '94287082',
        reason: 'purge did not remove the new record',
      );
    });

    test(
      'durable metadata down: every operation fails closed and changes nothing',
      () async {
        final c = FakeSeedCustody();
        await prov(c, epoch: 0);
        c.metadataDown = true;
        await expectLater(
          gen(c),
          custodyFails(CustodyError.metadataUnavailable),
        );
        await expectLater(
          c.clearOwner('o1', epoch: 0),
          custodyFails(CustodyError.metadataUnavailable),
        );
        await expectLater(
          prov(c, entry: 'e2'),
          custodyFails(CustodyError.metadataUnavailable),
        );
        await expectLater(
          c.delete('o1', 'e1', seedVersion: 1),
          custodyFails(CustodyError.metadataUnavailable),
        );
        await expectLater(
          c.enableOwner('o1', epoch: 1),
          custodyFails(CustodyError.metadataUnavailable),
        );
        await expectLater(
          c.reconcile(
            'o1',
            CustodySnapshot(
              epoch: 0,
              revision: 1,
              complete: true,
              versions: const {},
              tombstones: const {},
            ),
          ),
          custodyFails(CustodyError.metadataUnavailable),
        );
        c.metadataDown = false;
        expect(c.entries('o1'), ['e1']);
        expect(await gen(c), '94287082');
      },
    );

    test('invalid owner or epoch values are refused', () async {
      final c = FakeSeedCustody();
      await expectLater(
        c.clearOwner('', epoch: 0),
        custodyFails(CustodyError.invalidInput),
      );
      await expectLater(
        c.clearOwner('o1', epoch: -1),
        custodyFails(CustodyError.invalidInput),
      );
      await expectLater(
        c.clearOwner('o1', epoch: custodyMaxSafeInt),
        custodyFails(CustodyError.invalidInput),
      );
      await expectLater(
        c.enableOwner('o1', epoch: -1),
        custodyFails(CustodyError.invalidInput),
      );
      await expectLater(
        prov(c, epoch: -1),
        custodyFails(CustodyError.invalidInput),
      );
      await expectLater(
        prov(c, version: custodyMaxSafeInt + 1),
        custodyFails(CustodyError.invalidInput),
      );
    });
  });

  group('reconcile', () {
    CustodySnapshot snap(
      Map<String, int> versions, {
      bool complete = true,
      Map<String, int> tombstones = const {},
      int epoch = 0,
      int revision = 1,
    }) => CustodySnapshot(
      epoch: epoch,
      revision: revision,
      complete: complete,
      versions: versions,
      tombstones: tombstones,
    );

    Future<FakeSeedCustody> three() async {
      final c = FakeSeedCustody();
      for (final e in ['a', 'b', 'c']) {
        await prov(c, entry: e, version: 2);
      }
      return c;
    }

    test('a partial snapshot never mass-deletes', () async {
      final c = await three();
      final r = await c.reconcile('o1', snap({'a': 2}, complete: false));
      expect(r.removed, isEmpty);
      expect(c.entries('o1')..sort(), ['a', 'b', 'c']);
    });

    test('a complete snapshot removes unlisted entries and reports what to provision', () async {
      final c = await three();
      final r = await c.reconcile('o1', snap({'a': 2, 'b': 3, 'd': 1}));
      expect(r.removed, ['c']);
      expect(r.needsProvision..sort(), ['b', 'd']);
      expect(c.entries('o1')..sort(), ['a']);
      expect(r.superseded, ['b']);
      await expectLater(
        gen(c, entry: 'c', version: 2),
        custodyFails(CustodyError.notFound),
      );
    });

    test('tombstones delete at or below their version, even in a partial snapshot, and keep a floor', () async {
      final c = await three();
      final r = await c.reconcile(
        'o1',
        snap({}, complete: false, tombstones: {'a': 2, 'b': 1, 'z': 5}),
      );
      expect(r.removed, ['a']);
      expect(c.entries('o1')..sort(), [
        'b',
        'c',
      ], reason: 'b is newer than its tombstone');
      await expectLater(
        prov(c, entry: 'a', version: 2),
        custodyFails(CustodyError.versionConflict),
      );
      await expectLater(
        prov(c, entry: 'z', version: 5),
        custodyFails(CustodyError.versionConflict),
        reason: 'tombstone without a local record',
      );
      await prov(c, entry: 'a', version: 3);
    });

    test('a listed version at or below its tombstone is a contradiction: refused whole, nothing applied', () async {
      final c = await three();
      for (final bad in [
        snap({'a': 2}, tombstones: {'a': 2}),
        snap({'a': 1}, tombstones: {'a': 2}),
      ]) {
        await expectLater(
          c.reconcile('o1', bad),
          custodyFails(CustodyError.invalidSnapshot),
        );
      }
      expect(c.entries('o1')..sort(), ['a', 'b', 'c']);
      final r = await c.reconcile(
        'o1',
        snap({'a': 3, 'b': 2, 'c': 2}, tombstones: {'a': 2}, revision: 2),
      );
      expect(r.removed, ['a']);
      expect(r.needsProvision, [
        'a',
      ], reason: 'a newer version after the tombstone is allowed');
    });

    test('invalid fields are refused whole', () async {
      final c = await three();
      for (final bad in [
        snap({'': 1}),
        snap({'a': 0}),
        snap({'a': custodyMaxSafeInt + 1}),
        snap({'a\n': 1}),
        snap({}, tombstones: {'a': -1}),
        snap({}, revision: 0),
        snap({}, epoch: -1),
        snap({}, epoch: custodyMaxSafeInt),
        snap({for (var i = 0; i < 5001; i++) 'e$i': 1}),
      ]) {
        await expectLater(
          c.reconcile('o1', bad),
          custodyFails(CustodyError.invalidSnapshot),
        );
      }
      await expectLater(
        c.reconcile('', snap({})),
        custodyFails(CustodyError.invalidInput),
      );
      expect(c.entries('o1')..sort(), ['a', 'b', 'c']);
    });

    test('a stale or replayed snapshot cannot undo a newer one', () async {
      final c = await three();
      await c.reconcile('o1', snap({'a': 2, 'b': 2}, revision: 5));
      await expectLater(
        c.reconcile('o1', snap({'a': 2, 'b': 2, 'c': 2}, revision: 4)),
        custodyFails(CustodyError.staleSnapshot),
      );
      await expectLater(
        c.reconcile('o1', snap({'a': 2}, revision: 5)),
        custodyFails(CustodyError.staleSnapshot),
      );
      expect(c.entries('o1')..sort(), ['a', 'b']);
      await c.reconcile('o1', snap({'a': 2, 'b': 2}, revision: 6));
    });

    test(
      'a snapshot from before an opt-out, or while disabled, is refused',
      () async {
        final c = await three();
        await c.reconcile('o1', snap({'a': 2}, revision: 9));
        await c.clearOwner('o1', epoch: 0);
        for (final e in [0, 1, 7]) {
          await expectLater(
            c.reconcile('o1', snap({'a': 2}, epoch: e, revision: 10)),
            custodyFails(CustodyError.disabled),
          );
        }
        await c.enableOwner('o1', epoch: 1);
        await expectLater(
          c.reconcile('o1', snap({'a': 2}, epoch: 0, revision: 11)),
          custodyFails(CustodyError.staleEpoch),
        );
        final r = await c.reconcile(
          'o1',
          snap({'a': 2}, epoch: 1, revision: 1),
        );
        expect(r.needsProvision, ['a']);
      },
    );

    test('a snapshot epoch above the local one is refused whole: no epoch advance, no floor reset, no removals', () async {
      final c = await three();
      await c.reconcile(
        'o1',
        snap({'a': 2, 'b': 2, 'c': 2}, tombstones: {'z': 4}, revision: 9),
      );
      for (final e in [1, 3, 99]) {
        await expectLater(
          c.reconcile('o1', snap({}, epoch: e, revision: 1)),
          custodyFails(CustodyError.epochMismatch),
        );
      }
      expect(c.entries('o1')..sort(), ['a', 'b', 'c']);
      expect(await gen(c, entry: 'a', version: 2), '94287082');
      await expectLater(
        prov(c, entry: 'z', version: 4),
        custodyFails(CustodyError.versionConflict),
        reason: 'floor kept',
      );
      await expectLater(
        prov(c, entry: 'a', version: 3, epoch: 1),
        custodyFails(CustodyError.epochMismatch),
      );
      // Revision order at the real epoch is intact.
      await expectLater(
        c.reconcile('o1', snap({'a': 2}, revision: 9)),
        custodyFails(CustodyError.staleSnapshot),
      );
      await c.reconcile('o1', snap({'a': 2, 'b': 2, 'c': 2}, revision: 10));
    });

    test(
      'only a local clear then enable moves reconcile to a new epoch',
      () async {
        final c = await three();
        await c.clearOwner('o1', epoch: 0);
        await c.enableOwner('o1', epoch: 1);
        final r = await c.reconcile(
          'o1',
          snap({'a': 2}, epoch: 1, revision: 1),
        );
        expect(r.needsProvision, ['a']);
        await expectLater(
          c.reconcile('o1', snap({'a': 2}, epoch: 0, revision: 50)),
          custodyFails(CustodyError.staleEpoch),
        );
      },
    );

    test('removed entries cannot be provisioned back by an older in-flight response', () async {
      final c = await three();
      await c.reconcile('o1', snap({'a': 2, 'b': 2}));
      await expectLater(
        prov(c, entry: 'c', version: 2),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, entry: 'c', version: 3);
    });

    test('reconcile works on a locked store: logical removal now, physical delete pending', () async {
      final c = await three();
      c.locked = true;
      final r = await c.reconcile('o1', snap({'a': 2, 'b': 2}));
      expect(r.removed, ['c']);
      expect(r.pendingPurge, ['c']);
      await expectLater(
        gen(c, entry: 'c', version: 2),
        custodyFails(CustodyError.denied),
      );
      c.locked = false;
      expect(await c.purgePending(), isEmpty);
      expect(c.entries('o1')..sort(), ['a', 'b']);
    });

    test('needsProvision skips entries already satisfied or floored', () async {
      final c = await three();
      final r = await c.reconcile('o1', snap({'a': 2, 'b': 1, 'c': 2}));
      expect(r.needsProvision, isEmpty);
    });

    test('a newer authoritative version denies the old local record at once, even locked, and the new version can still be provisioned', () async {
      final c = await three();
      c.locked = true;
      final r = await c.reconcile('o1', snap({'a': 3, 'b': 2, 'c': 2}));
      expect(r.superseded, ['a']);
      expect(r.needsProvision, ['a']);
      expect(r.removed, isEmpty);
      await expectLater(
        gen(c, entry: 'a', version: 2),
        custodyFails(CustodyError.denied),
      );
      expect(await c.purgePending(), ['o1/a'], reason: 'still locked');
      c.locked = false;
      expect(await c.purgePending(), isEmpty);
      await expectLater(
        prov(c, entry: 'a', version: 2),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, entry: 'a', version: 3);
      expect(await gen(c, entry: 'a', version: 3), '94287082');
      // Other entries kept working throughout.
      expect(await gen(c, entry: 'b', version: 2), '94287082');
    });

    test('authoritative version is a minimum-accepted floor: local 1, snapshot 10, delayed 2 is rejected', () async {
      final c = FakeSeedCustody();
      await prov(c, entry: 'a', version: 1);
      await c.reconcile('o1', snap({'a': 10}));
      await expectLater(
        gen(c, entry: 'a', version: 1),
        custodyFails(CustodyError.notFound),
      );
      for (final v in [1, 2, 9]) {
        await expectLater(
          prov(c, entry: 'a', version: v),
          custodyFails(CustodyError.versionConflict),
          reason: 'v$v',
        );
      }
      await prov(c, entry: 'a', version: 10);
      expect(await gen(c, entry: 'a', version: 10), '94287082');
    });

    test('absent local record: snapshot 10 rejects provision 9, accepts 10 and later', () async {
      final c = FakeSeedCustody();
      final r = await c.reconcile('o1', snap({'a': 10}));
      expect(r.needsProvision, ['a']);
      await expectLater(
        prov(c, entry: 'a', version: 9),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, entry: 'a', version: 10);
      await prov(c, entry: 'b', version: 12, epoch: 0); // other entry, no floor
    });

    test('minimum-accepted differs from a tombstone: tombstone 10 denies 10, listed 10 allows it', () async {
      final c = FakeSeedCustody();
      await c.reconcile('o1', snap({}, tombstones: {'t': 10}));
      await expectLater(
        prov(c, entry: 't', version: 10),
        custodyFails(CustodyError.versionConflict),
      );
      await prov(c, entry: 't', version: 11);
      await c.reconcile('o1', snap({'l': 10}, revision: 2));
      await prov(c, entry: 'l', version: 10);
    });

    test(
      'a lower later snapshot never lowers the minimum-accepted floor',
      () async {
        final c = FakeSeedCustody();
        await c.reconcile('o1', snap({'a': 10}));
        await c.reconcile('o1', snap({'a': 4}, revision: 2));
        await expectLater(
          prov(c, entry: 'a', version: 9),
          custodyFails(CustodyError.versionConflict),
        );
      },
    );

    test(
      'a snapshot version older than the local record changes nothing',
      () async {
        final c = await three();
        final r = await c.reconcile('o1', snap({'a': 1, 'b': 2, 'c': 2}));
        expect(r.superseded, isEmpty);
        expect(r.removed, isEmpty);
        expect(r.needsProvision, isEmpty);
        expect(await gen(c, entry: 'a', version: 2), '94287082');
      },
    );

    test('reconcile affects only the named owner', () async {
      final c = await three();
      await prov(c, owner: 'o2', entry: 'z');
      await c.reconcile('o1', snap({}));
      expect(c.entries('o1'), isEmpty);
      expect(c.entries('o2'), ['z']);
    });
  });
}
