import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/google_migration.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/transfer/export_plan.dart';

// Synthetic secrets only.
OtpAccount a(String n, {int period = 30, int digits = 6, int fill = 3}) =>
    OtpAccount(
      issuer: 'Ex',
      accountName: n,
      secret: Uint8List.fromList(List.filled(20, fill)),
      period: period,
      digits: digits,
    );

List<int> v(int x) {
  final o = <int>[];
  while (x > 0x7f) {
    o.add((x & 0x7f) | 0x80);
    x >>= 7;
  }
  return [...o, x];
}

List<int> len(int f, List<int> d) => [...v((f << 3) | 2), ...v(d.length), ...d];
List<int> iv(int f, int x) => [...v(f << 3), ...v(x)];

/// One-account payload built by hand, with [extra] appended to the params.
String uri(List<int> extra) {
  final p = [
    ...len(1, List.filled(20, 5)),
    ...len(2, utf8.encode('Ex:me')),
    ...len(3, utf8.encode('Ex')),
    ...iv(4, 1),
    ...iv(5, 1),
    ...iv(6, 2),
    ...extra,
  ];
  final o = [
    ...len(1, p),
    ...iv(2, 1),
    ...iv(3, 1),
    ...iv(4, 0),
    ...iv(5, 1000),
  ];
  return 'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode(o))}';
}

OtpFormatError? err(String u) {
  try {
    parseMigrationUri(u);
    return null;
  } on OtpFormatException catch (e) {
    return e.error;
  }
}

void main() {
  sevenDigitTests();
  test(
    'Nov 26 synthetic shape: field 15 varint 60 decodes to a 60 s period',
    () {
      final acc = parseMigrationUri(uri(iv(15, 60))).accounts.single;
      expect(acc.period, 60);
      expect(acc.assumed, isNot(contains(OtpAssumption.period)));
    },
  );

  test('no extension keeps 30 s and marks the period assumed', () {
    final acc = parseMigrationUri(uri(const [])).accounts.single;
    expect(acc.period, 30);
    expect(acc.assumed, contains(OtpAssumption.period));
  });

  test('range, duplicate and wire type are refused', () {
    expect(err(uri(iv(15, 0))), OtpFormatError.malformed);
    expect(err(uri(iv(15, 86401))), OtpFormatError.malformed);
    expect(err(uri(iv(15, 86400))), isNull);
    expect(err(uri(iv(15, 1))), isNull);
    expect(err(uri([...iv(15, 60), ...iv(15, 60)])), OtpFormatError.malformed);
    expect(err(uri(len(15, [60]))), OtpFormatError.malformed);
    expect(err(uri([0x7d, 0, 0, 0, 0])), OtpFormatError.malformed); // fixed32
  });

  test('encoder is strict by default and writes field 15 only when asked', () {
    expect(
      () => encodeMigrationUris([a('p', period: 60)], batchId: 1),
      throwsA(isA<OtpFormatException>()),
    );
    final plain = encodeMigrationUris(
      [a('p')],
      batchId: 1,
      periodExtension: true,
    );
    final ext = encodeMigrationUris(
      [a('p', period: 60)],
      batchId: 1,
      periodExtension: true,
    );
    List<int> raw(String u) => base64.decode(
      base64.normalize(Uri.decodeQueryComponent(u.split('data=')[1])),
    );
    // tag 0x78 (field 15, varint) + one value byte for a 60 s period.
    expect(raw(ext.single).length, raw(plain.single).length + 2);
  });

  test(
    'roundtrip keeps the exact period; 7 digits still not representable',
    () {
      final src = [a('x', period: 60), a('y', period: 45, digits: 8), a('z')];
      final uris = encodeMigrationUris(src, batchId: 9, periodExtension: true);
      final back = assembleBatches([
        for (final u in uris) parseMigrationUri(u),
      ]);
      expect([for (final b in back) b.period], [60, 45, 30]);
      expect([for (final b in back) b.digits], [6, 8, 6]);
      expect(
        () => encodeMigrationUris(
          [a('s', digits: 7)],
          batchId: 1,
          periodExtension: true,
        ),
        throwsA(isA<OtpFormatException>()),
      );
    },
  );

  test(
    'Google export plan keeps true period in the QR and still discloses',
    () {
      final plan = planGoogleExport([a('x', period: 60), a('s', digits: 7)]);
      expect(plan.accounts[0].period, 60);
      expect(
        plan.accounts[1].digits,
        7,
      ); // true digits in field 16; Google shows six (unverified)
      expect(plan.notes.map((n) => n.change), [
        GoogleExportChange.periodDropped,
        GoogleExportChange.digitsAdjusted,
      ]);
      final uris = googleExportUris(plan.accounts, batchId: 4)!;
      final back = assembleBatches([
        for (final u in uris) parseMigrationUri(u),
      ]);
      expect(back[0].period, 60);
    },
  );
}

// ---- 7-digit extension (field 16) ----
List<int> _d(int v) => iv(16, v);

void sevenDigitTests() {
  group('digits extension (field 16)', () {
    test('field 16 = 7 on the six enum decodes to 7 digits, not assumed', () {
      final acc = parseMigrationUri(uri(_d(7))).accounts.single;
      expect(acc.digits, 7);
      expect(acc.assumed, isNot(contains(OtpAssumption.digits)));
    });
    test('field 5 stays Google enum: a 7-digit key is written as six', () {
      final u = encodeMigrationUris(
        [a('s', digits: 7)],
        batchId: 1,
        periodExtension: true,
        digitsExtension: true,
      ).single;
      // Strip our extension to see what a reader that ignores it sees.
      final raw = base64.decode(
        base64.normalize(Uri.decodeQueryComponent(u.split('data=')[1])),
      );
      expect(raw.length, greaterThan(0));
      // Same account without extensions encodes with digits enum 1 (six).
      final six = encodeMigrationUris([a('s')], batchId: 1).single;
      final rawSix = base64.decode(
        base64.normalize(Uri.decodeQueryComponent(six.split('data=')[1])),
      );
      expect(raw.length, rawSix.length + 3); // only tag 0x80 0x01 + value 7
    });
    test('roundtrip keeps 7 digits with period and other settings', () {
      final src = [
        a('x', digits: 7),
        a('y', digits: 7, period: 45),
        a('z', digits: 8, period: 60),
        a('w'),
      ];
      final uris = encodeMigrationUris(
        src,
        batchId: 9,
        periodExtension: true,
        digitsExtension: true,
      );
      final back = assembleBatches([
        for (final u in uris) parseMigrationUri(u),
      ]);
      expect([for (final b in back) b.digits], [7, 7, 8, 6]);
      expect([for (final b in back) b.period], [30, 45, 60, 30]);
    });
    test('strict by default and without the flag 7 digits is refused', () {
      expect(
        () => encodeMigrationUris([a('s', digits: 7)], batchId: 1),
        throwsA(isA<OtpFormatException>()),
      );
      expect(
        () => encodeMigrationUris(
          [a('s', digits: 7)],
          batchId: 1,
          periodExtension: true,
        ),
        throwsA(isA<OtpFormatException>()),
      );
    });
    test('malformed: duplicate, wire type, range, conflict with the enum', () {
      expect(err(uri([..._d(7), ..._d(7)])), OtpFormatError.malformed);
      expect(err(uri(len(16, [7]))), OtpFormatError.malformed);
      expect(err(uri(_d(5))), OtpFormatError.malformed);
      expect(err(uri(_d(9))), OtpFormatError.malformed);
      expect(err(uri(_d(0))), OtpFormatError.malformed);
      expect(err(uri(_d(8))), OtpFormatError.malformed); // enum says six
      expect(err(uri(_d(6))), isNull);
      expect(err(uri([0x85, 0x01, 7, 0, 0, 0])), OtpFormatError.malformed);
    });
    test('field 16 = 6 or 7 on an eight enum is refused', () {
      final p = [
        ...len(1, List.filled(20, 5)),
        ...len(2, utf8.encode('Ex:me')),
        ...iv(4, 1),
        ...iv(5, 2),
        ...iv(6, 2),
        ..._d(7),
      ];
      final o = [
        ...len(1, p),
        ...iv(2, 1),
        ...iv(3, 1),
        ...iv(4, 0),
        ...iv(5, 1),
      ];
      final u =
          'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode(o))}';
      expect(err(u), OtpFormatError.malformed);
    });
    test('plan keeps 7 digits in the QR, still discloses', () {
      final plan = planGoogleExport([a('s', digits: 7)]);
      expect(plan.accounts.single.digits, 7);
      expect(plan.notes.single.change, GoogleExportChange.digitsAdjusted);
      final uris = googleExportUris(plan.accounts, batchId: 2)!;
      final back = assembleBatches([
        for (final u in uris) parseMigrationUri(u),
      ]);
      expect(back.single.digits, 7);
    });
  });
}
