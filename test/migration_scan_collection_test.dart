import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/google_migration.dart';
import 'package:otpanda_client/offline_totp/migration_scan_collection.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';

void main() {
  OtpAccount account(String name, [int fill = 1]) => OtpAccount(
    issuer: 'Example',
    accountName: name,
    secret: Uint8List.fromList(List.filled(20, fill)),
  );
  test('single QR allows review and marks existing account duplicate', () {
    final scan = MigrationScanCollection()
      ..scan(
        encodeMigrationUris([
          account('one'),
          account('two'),
        ], batchId: 1).single,
      );
    expect(scan.complete, true);
    expect(scan.reviewedAccounts().length, 2);
    expect(
      scan
          .preview(existing: {('Example', 'one')})
          .map((e) => e.duplicateOfExisting),
      [true, false],
    );
  });
  test('multi QR out of order waits for all parts and repeated frames do not double import', () {
    final qr = encodeMigrationUris(
      [account('one'), account('two'), account('three')],
      batchId: 2,
      perBatch: 1,
    );
    final scan = MigrationScanCollection()
      ..scan(qr[2])
      ..scan(qr[2]);
    expect(scan.collected, 1);
    expect(scan.expected, 3);
    expect(scan.complete, false);
    expect(scan.reviewedAccounts, throwsA(isA<OtpFormatException>()));
    scan.scan(qr[0]);
    scan.scan(qr[1]);
    expect(scan.reviewedAccounts().map((a) => a.accountName), [
      'one',
      'two',
      'three',
    ]);
  });
  test(
    'mixed or conflicting batches refuse without dropping collected parts',
    () {
      final scan = MigrationScanCollection()
        ..scan(encodeMigrationUris([account('one')], batchId: 3).single);
      expect(
        () => scan.scan(
          encodeMigrationUris([account('one', 2)], batchId: 3).single,
        ),
        throwsA(isA<OtpFormatException>()),
      );
      expect(
        () =>
            scan.scan(encodeMigrationUris([account('two')], batchId: 4).single),
        throwsA(isA<OtpFormatException>()),
      );
      expect(scan.reviewedAccounts().single.accountName, 'one');
      scan.clear();
      expect(scan.collected, 0);
      expect(scan.complete, false);
    },
  );
  test('malformed scan reveals no input in error', () {
    final scan = MigrationScanCollection();
    try {
      scan.scan('private input');
      fail('accepted');
    } on OtpFormatException catch (e) {
      expect(e.toString(), isNot(contains('private input')));
    }
    expect(scan.collected, 0);
    expect(scan.toString(), isNot(contains('private input')));
  });
}
