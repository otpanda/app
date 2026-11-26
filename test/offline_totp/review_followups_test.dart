// Reviewer follow-ups: shared representability rule, unspecified type,
// all-skipped multipart, identifiable skips, persisted assumptions.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

import 'offline_totp_test.dart' show fails, rfcB32;

const allSkipped =
    'otpauth-migration://offline?data=CigKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgJoMRoGSG90cENvIAEoATABCicKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgJtMRoFTWQ1Q28gBCgBMAIQARgCIAAoKg%3D%3D';
const withTypeless =
    'otpauth-migration://offline?data=CiYKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgJvaxoET2theSABKAEwAgouChQxMjM0NTY3ODkwMTIzNDU2Nzg5MBIIdHlwZWxlc3MaBk5vVHlwZSABKAEwABABGAIgASgq';
const bidiLabel =
    'otpauth-migration://offline?data=CiwKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgtiaWRp4oCuZXZpbBoBWCABKAEwARABGAEgACgr';

void main() {
  test(
    'planner calls the predicate it is given, defaulting to the shared one',
    () {
      final base = OtpAccount(
        issuer: null,
        accountName: 'x',
        secret: Uint8List.fromList(List<int>.generate(20, (i) => i + 1)),
      );
      final eight = base.withParameters(digits: 8);
      final seen = <OtpAccount>[];
      final plan = planMigrationExport(
        [base, eight],
        representable: (a) {
          seen.add(a);
          return a.digits == 6;
        },
      );
      expect(seen, [base, eight]);
      expect(plan.google, [base]);
      expect(plan.otpauthOnly, [eight]);
      final d = planMigrationExport([base, eight]);
      expect(d.google, [
        base,
        eight,
      ], reason: 'default is isMigrationRepresentable');
    },
  );

  test('planner and encoder share one representability rule', () {
    final secret = List<int>.generate(20, (i) => i + 1);
    for (final period in [1, 15, 30, 31, 60, 86400]) {
      for (final digits in [6, 8]) {
        final a = OtpAccount(
          issuer: null,
          accountName: 'x',
          secret: Uint8List.fromList(secret),
          digits: digits,
          period: period,
        );
        final plan = planMigrationExport([a]);
        final ok = plan.google.length == 1;
        expect(ok, isMigrationRepresentable(a));
        if (ok) {
          expect(encodeMigrationUris([a], batchId: 1), isNotEmpty);
        } else {
          expect(
            () => encodeMigrationUris([a], batchId: 1),
            fails(OtpFormatError.notRepresentable),
          );
        }
      }
    }
  });

  test('7 digits are valid, but only an otpauth/Aegis/Bitwarden export can carry them', () {
    final a = OtpAccount(
      issuer: null,
      accountName: 'x',
      secret: Uint8List(20)..[0] = 1,
      digits: 7,
    );
    expect(a.digits, 7);
    expect(isMigrationRepresentable(a), isFalse);
    final plan = planMigrationExport([a]);
    expect(plan.google, isEmpty);
    expect(plan.otpauthOnly, [a]);
    expect(
      () => encodeMigrationUris([a], batchId: 1),
      fails(OtpFormatError.notRepresentable),
    );
    expect(parseOtpauthUri(encodeOtpauthUri(a)).digits, 7);
    expect(
      () => OtpAccount(
        issuer: null,
        accountName: 'x',
        secret: Uint8List(20),
        digits: 9,
      ),
      fails(OtpFormatError.unsupportedDigits),
    );
  });

  test(
    'an unspecified entry type is skipped as unsupported, not read as TOTP',
    () {
      final b = parseMigrationUri(withTypeless, skipUnsupported: true);
      expect(b.accounts.map((a) => a.accountName), ['ok']);
      expect(b.skipped.single.error, OtpFormatError.unsupportedType);
      expect(b.skipped.single.accountName, 'typeless');
      expect(
        () => parseMigrationUri(withTypeless),
        fails(OtpFormatError.unsupportedType),
      );
    },
  );

  test('a batch where every entry is skipped still assembles, with identifiable skips', () {
    final a = parseMigrationUri(allSkipped, skipUnsupported: true);
    expect(a.accounts, isEmpty);
    expect(a.skipped.length, 2);
    final b = parseMigrationUri(withTypeless, skipUnsupported: true);
    final out = assembleBatchesWithSkipped([b, a]);
    expect(out.accounts.map((x) => x.accountName), ['ok']);
    expect(out.skipped.map((s) => (s.position, s.accountName, s.issuer)), [
      (1, 'h1', 'HotpCo'),
      (2, 'm1', 'Md5Co'),
      (4, 'typeless', 'NoType'),
    ]);
    expect(
      () => assembleBatchesWithSkipped([a]),
      fails(OtpFormatError.incompleteBatch),
    );
  });

  test(
    'a single batch with nothing importable yields an empty import plus skips',
    () {
      final c = parseMigrationUri(bidiLabel, skipUnsupported: true);
      final out = assembleBatchesWithSkipped([c]);
      expect(out.accounts, isEmpty);
      expect(out.skipped.single.error, OtpFormatError.unsupportedType);
      expect(out.skipped.single.issuer, 'X');
      expect(
        out.skipped.single.accountName,
        isNull,
        reason: 'bidi label withheld',
      );
    },
  );

  test('skip toString never carries labels', () {
    final a = parseMigrationUri(allSkipped, skipUnsupported: true);
    expect(a.skipped.join(), isNot(contains('h1')));
    expect(a.skipped.join(), isNot(contains('HotpCo')));
  });

  test('list skips are identifiable when the label is safe', () {
    final out = parseOtpauthList(
      'otpauth://totp/Ok:me?secret=$rfcB32&issuer=Ok\n'
      'otpauth://hotp/Old%20Co:legacy?secret=$rfcB32&counter=3\n',
    );
    expect(out.skipped.single.issuer, 'Old Co');
    expect(out.skipped.single.accountName, 'legacy');
  });

  test('assumption provenance has a stable, strict storage form', () {
    final all = OtpAssumption.values.toSet();
    final names = OtpAssumption.encodeAll(all);
    expect(names, ['algorithm', 'digits', 'period']);
    expect(OtpAssumption.decodeAll(names), all);
    expect(OtpAssumption.decodeAll(const []), isEmpty);
    expect(
      () => OtpAssumption.decodeAll(['period', 'period']),
      fails(OtpFormatError.malformed),
    );
    expect(
      () => OtpAssumption.decodeAll(['periodd']),
      fails(OtpFormatError.malformed),
    );
    final restored = OtpAccount(
      issuer: null,
      accountName: 'x',
      secret: Uint8List(20),
      assumed: OtpAssumption.decodeAll(['period']),
    );
    expect(restored.assumed, {OtpAssumption.period});
    expect(restored.withParameters(period: 45).assumed, isEmpty);
  });
}
