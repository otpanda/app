import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/transfer/batch_import_saver.dart';
import 'package:otpanda_client/transfer/import_review.dart';

import 'dart:typed_data';

class Passkey implements PasskeyAssertionSource {
  @override
  bool available = true;
  int calls = 0;
  bool cancel = false;
  @override
  Future<String?> get(String request) async {
    calls++;
    return cancel
        ? null
        : '{"id":"cid","rawId":"cid","type":"public-key","response":{"clientDataJSON":"cd","authenticatorData":"ad","signature":"sg","userHandle":null}}';
  }
}

void main() {
  final accounts = [
    for (var i = 0; i < 2; i++)
      OtpAccount(
        issuer: 'Synthetic',
        accountName: 'a$i',
        secret: Uint8List(20)..fillRange(0, 20, 42),
      ),
  ];
  Map<String, dynamic> challenge() => {
    'token': 'otpda_${'A' * 55}',
    'expiresAt': 1060000,
    'options': {
      'challenge': 'A' * 43,
      'rpId': 'otpanda.github.io',
      'userVerification': 'required',
      'timeout': 60000,
      'allowCredentials': [
        {'id': 'Y2lk', 'type': 'public-key'},
      ],
    },
  };
  test('definite save retires attempt so another reviewed batch gets a fresh nonce', () async {
    final pk = Passkey(), nonces = <Object?>[];
    final saver = BatchImportSaver(
      passkeys: pk,
      current: () async => true,
      nowMs: () => 1000000,
      post: (path, body) async {
        nonces.add(body['batchNonce']);
        if (path.endsWith('batch-begin')) {
          return (status: 200, body: challenge());
        }
        return (
          status: 201,
          body: <String, dynamic>{
            'entryIds': (body['items'] as List).length == 2
                ? ['one', 'two']
                : ['third'],
          },
        );
      },
    );
    expect(await saver.save(accounts), ImportSaveOutcome.saved);
    expect(await saver.save([accounts.first]), ImportSaveOutcome.saved);
    expect(nonces[0], nonces[1]);
    expect(nonces[2], nonces[3]);
    expect(nonces[0], isNot(nonces[2]));
    expect(pk.calls, 2);
  });
  test(
    'whole reviewed batch sends one begin and finish under one prompt',
    () async {
      final calls = <String>[], p = Passkey();
      final saver = BatchImportSaver(
        passkeys: p,
        current: () async => true,
        nowMs: () => 1000000,
        post: (path, body) async {
          calls.add(path);
          if (path.endsWith('batch-begin')) {
            return (status: 200, body: challenge());
          }
          return (
            status: 201,
            body: <String, dynamic>{
              'entryIds': ['one', 'two'],
            },
          );
        },
      );
      expect(await saver.save(accounts), ImportSaveOutcome.saved);
      expect(p.calls, 1);
      expect(calls.length, 2);
    },
  );
  test('cancel never finishes, over50 never begins', () async {
    final calls = <String>[], p = Passkey()..cancel = true;
    final saver = BatchImportSaver(
      passkeys: p,
      current: () async => true,
      nowMs: () => 1000000,
      post: (path, body) async {
        calls.add(path);
        return (status: 200, body: challenge());
      },
    );
    expect(await saver.save(accounts), ImportSaveOutcome.cancelled);
    expect(calls.length, 1);
    expect(
      await saver.save(List.filled(51, accounts.first)),
      ImportSaveOutcome.notSaved,
    );
    expect(calls.length, 1);
  });
  test('unknown finish preserves nonce and changed selection cannot create another attempt', () async {
    final nonces = <Object?>[], p = Passkey();
    var phase = 0;
    final saver = BatchImportSaver(
      passkeys: p,
      current: () async => true,
      nowMs: () => 1000000,
      post: (path, body) async {
        nonces.add(body['batchNonce']);
        if (path.endsWith('batch-begin')) {
          if (phase++ == 0) return (status: 200, body: challenge());
          return (
            status: 200,
            body: <String, dynamic>{
              'status': 'saved',
              'entryIds': ['one', 'two'],
            },
          );
        }
        throw StateError('lost reply');
      },
    );
    expect(await saver.save(accounts), ImportSaveOutcome.unknown);
    expect(await saver.save([accounts.first]), ImportSaveOutcome.unknown);
    expect(await saver.save(accounts), ImportSaveOutcome.saved);
    expect(nonces.toSet().length, 1);
    expect(p.calls, 1);
  });
}
