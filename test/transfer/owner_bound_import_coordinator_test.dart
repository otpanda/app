import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/transfer/owner_bound_import_coordinator.dart';
import 'package:otpanda_client/transfer/import_review.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';

import 'batch_import_saver_test.dart' show Journal, Passkey;

void main() {
  test('scanner and settings share verified owner, one pending journal blocks both', () async {
    final journal = Journal(), passkey = Passkey();
    var begins = 0, finishes = 0;
    var current = true;
    final coordinator = OwnerBoundImportCoordinator(
      deviceId: 'device',
      current: () async => current,
      readSession: () async => (status: 200, body: '{"ownerId":"owner"}'),
      journal: journal,
      passkeys: passkey,
      post: (path, body) async {
        if (path.endsWith('batch-begin')) {
          begins++;
          return (
            status: 200,
            body: <String, dynamic>{
              'protocol': 2,
              'admissionId': 'B' * 32,
              'status': 'saved',
              'entryIds': ['one'],
            },
          );
        }
        finishes++;
        return (status: 503, body: null);
      },
    );
    final a = [
      OtpAccount(
        issuer: null,
        accountName: 'a',
        secret: Uint8List.fromList(List.filled(20, 42)),
      ),
    ];
    expect(await coordinator.save(a), ImportSaveOutcome.saved);
    expect(await coordinator.save(a), ImportSaveOutcome.blocked);
    expect(begins, 1);
    expect(finishes, 0);
    expect(await coordinator.acknowledgeShown(), true);
    expect(await coordinator.save(a), ImportSaveOutcome.saved);
    expect(begins, 2);
    current = false;
    expect(await coordinator.save(a), ImportSaveOutcome.blocked);
    expect(begins, 2);
  });
  test(
    'identity change during owner verification blocks before any begin',
    () async {
      final gate = Completer<({int status, String body})>();
      var current = true, posts = 0;
      final c = OwnerBoundImportCoordinator(
        deviceId: 'device',
        current: () async => current,
        readSession: () => gate.future,
        journal: Journal(),
        passkeys: Passkey(),
        post: (p, b) async {
          posts++;
          return (status: 200, body: null);
        },
      );
      final attempt = c.save([
        OtpAccount(
          issuer: null,
          accountName: 'a',
          secret: Uint8List.fromList(List.filled(20, 42)),
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      current = false;
      gate.complete((status: 200, body: '{"ownerId":"owner"}'));
      expect(await attempt, ImportSaveOutcome.blocked);
      expect(posts, 0);
    },
  );
}
