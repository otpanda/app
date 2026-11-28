import 'dart:async';

import 'package:otpanda_client/import_recovery_journal.dart';
import 'package:otpanda_client/native/native_device_routes.dart'
    show DevicePost;
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

class Journal implements ImportJournal {
  ImportAttempt? value;
  @override
  Future<ImportAttempt?> read() async => value;
  @override
  Future<bool> claim(ImportAttempt r) async {
    if (value != null) return false;
    value = r;
    return true;
  }

  @override
  Future<bool> replace(ImportAttempt r, ImportAttempt n) async {
    if (value?.encode() != r.encode()) return false;
    value = n;
    return true;
  }

  @override
  Future<bool> clear(ImportAttempt r) async {
    if (value?.encode() != r.encode()) return false;
    value = null;
    return true;
  }
}

BatchImportSaver makeSaver({
  required DevicePost post,
  required PasskeyAssertionSource passkeys,
  required Future<bool> Function() current,
  int Function()? nowMs,
}) => BatchImportSaver(
  post: post,
  passkeys: passkeys,
  current: current,
  nowMs: nowMs,
  recovery: ImportRecoveryBarrier(
    journal: Journal(),
    ownerId: 'owner',
    deviceId: 'device',
    current: current,
    fence: (body) => post('/v1/manage/totp/batch-outcome', body),
  ),
);

void main() {
  test('old review acknowledgement cannot acknowledge the next explicitly saved result', () async {
    final j = Journal();
    final saver = BatchImportSaver(
      post: (p, b) async => (
        status: 200,
        body: <String, dynamic>{
          'protocol': 2,
          'admissionId': 'B' * 32,
          'status': 'saved',
          'entryIds': ['one'],
        },
      ),
      passkeys: Passkey(),
      current: () async => true,
      recovery: ImportRecoveryBarrier(
        journal: j,
        ownerId: 'owner',
        deviceId: 'device',
        current: () async => true,
        fence: (b) async => (status: 500, body: null),
      ),
    );
    final selection = [
      OtpAccount(
        issuer: null,
        accountName: 'a',
        secret: Uint8List.fromList(List.filled(20, 42)),
      ),
    ];
    expect(await saver.save(selection), ImportSaveOutcome.saved);
    final ackA = saver.captureShownAcknowledgement();
    expect(await ackA(), true);
    expect(await saver.save(selection), ImportSaveOutcome.saved);
    final second = j.value!.encode();
    final ackB = saver.captureShownAcknowledgement();
    expect(await ackA(), false);
    expect(j.value?.encode(), second);
    expect(await ackB(), true);
    expect(j.value, null);
  });

  test('acknowledgement cannot clear a different terminal than the presented attempt', () async {
    final j = Journal();
    final saver = BatchImportSaver(
      post: (p, b) async => (
        status: 200,
        body: <String, dynamic>{
          'protocol': 2,
          'admissionId': 'B' * 32,
          'status': 'saved',
          'entryIds': ['one'],
        },
      ),
      passkeys: Passkey(),
      current: () async => true,
      recovery: ImportRecoveryBarrier(
        journal: j,
        ownerId: 'owner',
        deviceId: 'device',
        current: () async => true,
        fence: (b) async => (status: 500, body: null),
      ),
    );
    expect(
      await saver.save([
        OtpAccount(
          issuer: null,
          accountName: 'a',
          secret: Uint8List.fromList(List.filled(20, 42)),
        ),
      ]),
      ImportSaveOutcome.saved,
    );
    final other = ImportAttempt(
      ownerId: 'owner',
      deviceId: 'device',
      nonce: 'v2:${'Z' * 32}',
      admissionId: 'C' * 32,
      count: 1,
    ).terminal('fenced');
    j.value = other;
    expect(await saver.acknowledgeShown(), false);
    expect(j.value?.encode(), other.encode());
    expect(await saver.reconcile(), ImportSaveOutcome.unknown);
  });

  test(
    'seeded terminal plus invalid selection never acknowledges unseen result',
    () async {
      for (final outcome in ['saved', 'fenced']) {
        final rec = ImportAttempt(
          ownerId: 'owner',
          deviceId: 'device',
          nonce: 'v2:${'A' * 32}',
          admissionId: 'B' * 32,
          count: 1,
        ).terminal(outcome);
        final j = Journal()..value = rec;
        var posts = 0;
        final saver = BatchImportSaver(
          post: (p, b) async {
            posts++;
            return (status: 500, body: null);
          },
          passkeys: Passkey(),
          current: () async => true,
          recovery: ImportRecoveryBarrier(
            journal: j,
            ownerId: 'owner',
            deviceId: 'device',
            current: () async => true,
            fence: (b) async => (status: 500, body: null),
          ),
        );
        expect(await saver.save([]), ImportSaveOutcome.blocked);
        expect(await saver.acknowledgeShown(), true);
        expect(j.value?.encode(), rec.encode());
        expect(posts, 0);
      }
    },
  );

  final accounts = [
    for (var i = 0; i < 2; i++)
      OtpAccount(
        issuer: 'Synthetic',
        accountName: 'a$i',
        secret: Uint8List(20)..fillRange(0, 20, 42),
      ),
  ];
  Map<String, dynamic> challenge() => {
    'protocol': 2,
    'admissionId': 'B' * 32,
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
  test(
    'whole reviewed batch sends one begin and finish under one prompt',
    () async {
      final calls = <String>[], p = Passkey();
      final saver = makeSaver(
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
    final saver = makeSaver(
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
    final saver = makeSaver(
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
    expect(await saver.save([accounts.first]), ImportSaveOutcome.blocked);
    expect(await saver.save(accounts), ImportSaveOutcome.blocked);
    expect(nonces.toSet().length, 1);
    expect(p.calls, 1);
  });

  // Scripted server: finish fails with [finishStatus] (or throws), outcome answers [fence].
  BatchImportSaver scripted(
    List<String> calls,
    Passkey p, {
    int? finishStatus,
    required Map<String, dynamic>? Function(Map<String, dynamic>) fence,
    int fenceStatus = 200,
  }) => makeSaver(
    passkeys: p,
    current: () async => true,
    nowMs: () => 1000000,
    post: (path, body) async {
      calls.add(
        '${path.split('/').last}${body['fence'] == true ? '+fence' : ''}',
      );
      if (path.endsWith('batch-begin')) return (status: 200, body: challenge());
      if (path.endsWith('batch-finish')) {
        if (finishStatus == null) throw StateError('lost reply');
        return (status: finishStatus, body: <String, dynamic>{});
      }
      return (status: fenceStatus, body: fence(body));
    },
  );
  test(
    '4xx finish never trusts a plain none: only a fence makes it notSaved',
    () async {
      final calls = <String>[];
      final saver = scripted(
        calls,
        Passkey(),
        finishStatus: 409,
        fence: (b) => {'status': 'fenced'},
      );
      expect(await saver.save(accounts), ImportSaveOutcome.notSaved);
      expect(calls, ['batch-begin', 'batch-finish', 'batch-outcome+fence']);
      expect(calls.contains('batch-outcome'), isFalse);
    },
  );
  test('late commit won: fence reports saved, not notSaved', () async {
    final saver = scripted(
      [],
      Passkey(),
      finishStatus: null,
      fence: (b) => {
        'status': 'saved',
        'entryIds': ['one', 'two'],
      },
    );
    expect(await saver.save(accounts), ImportSaveOutcome.saved);
  });
  test('fence unreachable stays unknown, keeps the nonce, and reconcile later resolves it without a second finish', () async {
    final calls = <String>[], nonces = <Object?>[];
    var up = false;
    final p = Passkey();
    final saver = makeSaver(
      passkeys: p,
      current: () async => true,
      nowMs: () => 1000000,
      post: (path, body) async {
        calls.add(path.split('/').last);
        nonces.add(body['batchNonce']);
        if (path.endsWith('batch-begin')) {
          return (status: 200, body: challenge());
        }
        if (path.endsWith('batch-finish')) throw StateError('lost reply');
        if (!up) throw StateError('offline');
        return (status: 200, body: <String, dynamic>{'status': 'fenced'});
      },
    );
    expect(await saver.save(accounts), ImportSaveOutcome.unknown);
    expect(await saver.reconcile(), ImportSaveOutcome.unknown);
    up = true;
    expect(await saver.reconcile(), ImportSaveOutcome.notSaved);
    expect(calls.where((c) => c == 'batch-finish').length, 1);
    expect(nonces.toSet().length, 1);
    // A terminal outcome remains until shown and explicitly acknowledged.
    expect(await saver.acknowledgeShown(), true);
    up = false;
    await saver.save(accounts);
    expect(nonces.toSet().length, 2);
  });
  test('malformed or error fence reply stays unknown', () async {
    for (final r in [
      <String, dynamic>{'status': 'none'},
      <String, dynamic>{
        'status': 'saved',
        'entryIds': ['x'],
      },
    ]) {
      final saver = scripted([], Passkey(), finishStatus: 500, fence: (b) => r);
      expect(await saver.save(accounts), ImportSaveOutcome.unknown);
    }
    final saver = scripted(
      [],
      Passkey(),
      finishStatus: 500,
      fence: (b) => {'status': 'fenced'},
      fenceStatus: 500,
    );
    expect(await saver.save(accounts), ImportSaveOutcome.unknown);
  });
  test(
    'already saved begin journals terminal without ceremony or finish',
    () async {
      final p = Passkey();
      var posts = 0;
      final s = makeSaver(
        passkeys: p,
        current: () async => true,
        post: (path, body) async {
          posts++;
          return (
            status: 200,
            body: <String, dynamic>{
              'protocol': 2,
              'status': 'saved',
              'admissionId': 'B' * 32,
              'entryIds': ['one', 'two'],
            },
          );
        },
      );
      expect(await s.save(accounts), ImportSaveOutcome.saved);
      expect(p.calls, 0);
      expect(posts, 1);
      expect((await s.recovery.journal.read())?.outcome, 'saved');
    },
  );
  test('concurrent entry cannot begin twice and restart journal prevents new begin', () async {
    final p = Passkey();
    final gate = Completer<void>();
    var begins = 0, finishes = 0;
    final j = Journal();
    Future<({int status, Map<String, dynamic>? body})> post(
      String path,
      Map<String, dynamic> body,
    ) async {
      if (path.endsWith('batch-begin')) {
        begins++;
        await gate.future;
        return (status: 200, body: challenge());
      }
      if (path.endsWith('batch-finish')) {
        finishes++;
        throw StateError('lost');
      }
      return (status: 503, body: null);
    }

    BatchImportSaver create() => BatchImportSaver(
      post: post,
      passkeys: p,
      current: () async => true,
      nowMs: () => 1000000,
      recovery: ImportRecoveryBarrier(
        journal: j,
        ownerId: 'owner',
        deviceId: 'device',
        current: () async => true,
        fence: (body) => post('/v1/manage/totp/batch-outcome', body),
      ),
    );
    final saver = create(), first = saver.save(accounts);
    await Future<void>.delayed(Duration.zero);
    expect(await saver.save(accounts), ImportSaveOutcome.blocked);
    gate.complete();
    expect(await first, ImportSaveOutcome.unknown);
    expect(await create().save(accounts), ImportSaveOutcome.blocked);
    expect(begins, 1);
    expect(finishes, 1);
    expect(j.value?.outcome, 'pending');
  });
  test('old saved record never reports new selection saved', () async {
    final s = makeSaver(
      passkeys: Passkey(),
      current: () async => true,
      nowMs: () => 1000000,
      post: (path, body) async => path.endsWith('batch-begin')
          ? (status: 200, body: challenge())
          : (
              status: 201,
              body: <String, dynamic>{
                'entryIds': ['one', 'two'],
              },
            ),
    );
    expect(await s.save(accounts), ImportSaveOutcome.saved);
    expect(await s.save([accounts.first]), ImportSaveOutcome.blocked);
    expect((await s.recovery.journal.read())?.outcome, 'saved');
  });
}
