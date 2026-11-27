import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_sync_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('inactive-seed-sync');
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Future<Object?> Function(MethodCall) handler;
  final pub = Uint8List.fromList([4, ...List.filled(64, 1)]);
  final key = 'a' * 32, install = 'I' * 43, handle = 'b' * 32;
  final sig = base64UrlEncode(List.filled(64, 1)).replaceAll('=', '');
  Matcher failure(SeedSyncFailureKind k) =>
      throwsA(isA<SeedSyncFailure>().having((e) => e.kind, 'kind', k));
  SeedSyncChannel adapter({Duration timeout = const Duration(seconds: 1)}) =>
      SeedSyncChannel(channel, timeout: timeout);
  Future<SeedEnrollment> enroll(SeedSyncChannel a) =>
      a.enroll(owner: 'owner', installId: install, generation: 1);
  setUp(() {
    calls.clear();
    handler = (c) async => switch (c.method) {
      'syncEnroll' => {
        'keyId': key,
        'publicKey': pub,
        'generation': 1,
        'installId': install,
      },
      'syncEnrollmentState' => {'keyId': key, 'provable': false},
      'syncBatchBegin' => {
        'handleId': handle,
        'ephemeralPublic': base64UrlEncode(pub).replaceAll('=', ''),
      },
      'syncBatchOpen' || 'syncBatchSkip' => {'pending': <String>[]},
      'syncErase' => {'seedsPurged': true, 'keyDeleted': true, 'epoch': 2},
      'syncSignEnrollProof' ||
      'syncSignSnapshotProof' ||
      'syncSignRevokeProof' ||
      'syncBatchSign' => sig,
      _ => null,
    };
    messenger.setMockMethodCallHandler(channel, (c) {
      calls.add(c);
      return handler(c);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'enrollment exact request, defensive public bytes and restart state',
    () async {
      final a = adapter(), e = await enroll(adapter());
      expect(e.keyId, key);
      expect(e.installId, install);
      expect(e.generation, 1);
      final bytes = e.publicKey;
      bytes[1] = 0;
      expect(e.publicKey[1], 1);
      expect(calls.single.arguments, {
        'owner': 'owner',
        'installId': install,
        'generation': 1,
      });
      final state = await a.state('owner');
      expect(state.keyId, key);
      expect(state.provable, false);
      expect(calls.map((c) => c.method), ['syncEnroll', 'syncEnrollmentState']);
    },
  );
  for (final row in {
    'NOT_ENROLLED': SeedSyncFailureKind.notEnrolled,
    'MISSING_KEY': SeedSyncFailureKind.missingKey,
    'UNAVAILABLE': SeedSyncFailureKind.unavailable,
    'METADATA_UNAVAILABLE': SeedSyncFailureKind.metadataUnavailable,
    'ERASE_INCOMPLETE': SeedSyncFailureKind.eraseIncomplete,
    'INSTALL_ID_UNREADABLE': SeedSyncFailureKind.installIdUnreadable,
    'INSTALL_ID_MISMATCH': SeedSyncFailureKind.installIdMismatch,
    'BUSY': SeedSyncFailureKind.busy,
    'INVALID_INPUT': SeedSyncFailureKind.invalidInput,
    'WIRE_KEY': SeedSyncFailureKind.wire,
    'EPOCH_MISMATCH': SeedSyncFailureKind.custody,
  }.entries) {
    test('${row.key} never retries, erases or reenrolls', () async {
      handler = (_) async => throw PlatformException(
        code: row.key,
        message: 'private platform text',
        details: pub,
      );
      await expectLater(enroll(adapter()), failure(row.value));
      expect(calls.map((c) => c.method), ['syncEnroll']);
    });
  }
  test('platform prose and unknown codes never escape failure', () async {
    handler = (_) async =>
        throw PlatformException(code: 'private unknown', message: 'secret');
    try {
      await enroll(adapter());
      fail('expected failure');
    } on SeedSyncFailure catch (e) {
      expect(e.kind, SeedSyncFailureKind.unknownOutcome);
      expect(e.toString(), isNot(contains('secret')));
      expect(e.toString(), isNot(contains('private')));
    }
  });
  test(
    'timeout has unknown mutation outcome, late completion triggers nothing',
    () async {
      final held = Completer<Object?>();
      handler = (_) => held.future;
      await expectLater(
        enroll(adapter(timeout: const Duration(milliseconds: 10))),
        failure(SeedSyncFailureKind.unknownOutcome),
      );
      held.complete({
        'keyId': key,
        'publicKey': pub,
        'generation': 1,
        'installId': install,
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls.length, 1);
    },
  );
  test('read timeout unavailable, missing host unavailable', () async {
    handler = (_) => Completer<Object?>().future;
    await expectLater(
      adapter(timeout: const Duration(milliseconds: 10)).state('owner'),
      failure(SeedSyncFailureKind.unavailable),
    );
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      enroll(adapter()),
      failure(SeedSyncFailureKind.unavailable),
    );
  });
  for (final mutation in [
    {'extra': 'not allowed'},
    {'generation': 2},
    {'installId': 'B' * 43},
    {'publicKey': List.filled(65, 4)},
    {'publicKey': Uint8List(65)},
    {'keyId': 'wrong'},
  ]) {
    test(
      'malformed enrollment reply ${mutation.keys.first} is refused without cleanup',
      () async {
        handler = (_) async => {
          'keyId': key,
          'publicKey': pub,
          'generation': 1,
          'installId': install,
          ...mutation,
        };
        await expectLater(
          enroll(adapter()),
          failure(SeedSyncFailureKind.unknownOutcome),
        );
        expect(calls.length, 1);
      },
    );
  }
  test('null key cannot be provable', () async {
    handler = (_) async => {'keyId': null, 'provable': true};
    await expectLater(
      adapter().state('owner'),
      failure(SeedSyncFailureKind.malformedReply),
    );
  });
  test(
    'explicit lifecycle reasons and pending result are not success',
    () async {
      final a = adapter();
      for (final r in SeedEraseReason.values) {
        expect(
          (await a.erase(owner: 'owner', epoch: 1, reason: r)).complete,
          true,
        );
      }
      expect(calls.map((c) => (c.arguments as Map)['trigger']), [
        'sign_out',
        'disable',
        'owner_switch',
      ]);
      handler = (_) async => {
        'seedsPurged': false,
        'keyDeleted': true,
        'epoch': 2,
      };
      expect(
        (await a.erase(
          owner: 'owner',
          epoch: 1,
          reason: SeedEraseReason.disable,
        )).complete,
        false,
      );
    },
  );
  test(
    'erase returns native effective epoch without guessed monotonic comparison',
    () async {
      handler = (_) async => {
        'seedsPurged': true,
        'keyDeleted': true,
        'epoch': 0,
      };
      expect(
        (await adapter().erase(
          owner: 'owner',
          epoch: 1,
          reason: SeedEraseReason.signOut,
        )).epoch,
        0,
      );
    },
  );
  test(
    'proofs forward only native contract fields and validate raw signature',
    () async {
      final a = adapter();
      expect(
        await a.enrollProof(
          owner: 'owner',
          keyId: key,
          challenge: install,
          actionDigest: '0' * 64,
          expiresAt: 1000,
        ),
        sig,
      );
      expect(
        await a.snapshotProof(
          owner: 'owner',
          keyId: key,
          deviceId: 'device',
          generation: 1,
          epoch: 0,
          challenge: install,
          expiresAt: 1000,
        ),
        sig,
      );
      expect(
        await a.revokeProof(
          owner: 'owner',
          keyId: key,
          deviceId: 'device',
          generation: 1,
          challenge: install,
          expiresAt: 1000,
        ),
        sig,
      );
      expect(calls.first.arguments, {
        'owner': 'owner',
        'keyId': key,
        'challenge': install,
        'expiresAt': 1000,
        'actionDigest': '0' * 64,
      });
      handler = (_) async => 'A' * 85 + 'B';
      await expectLater(
        a.enrollProof(
          owner: 'owner',
          keyId: key,
          challenge: install,
          actionDigest: '0' * 64,
          expiresAt: 1000,
        ),
        failure(SeedSyncFailureKind.malformedReply),
      );
    },
  );
  test(
    'batch preserves native base64 point, methods, sealed bytes stay text',
    () async {
      final a = adapter();
      final start = await a.begin(
        owner: 'owner',
        deviceId: 'device',
        generation: 1,
        epoch: 0,
        entries: const [SeedBatchEntry('entry', 1, 'SHA-1', 6, 30)],
      );
      expect(start.handleId, handle);
      expect(start.ephemeralPublic, base64UrlEncode(pub).replaceAll('=', ''));
      await a.bind(handle, challenge: install, expiresAt: 1000);
      expect(await a.signBatch(handle), sig);
      expect(
        await a.open(
          handle,
          entryId: 'entry',
          serverPublicKey: base64UrlEncode(pub).replaceAll('=', ''),
          nonce: base64UrlEncode(List.filled(12, 1)).replaceAll('=', ''),
          ciphertext: base64UrlEncode(List.filled(36, 1)).replaceAll('=', ''),
        ),
        isEmpty,
      );
      expect(await a.skip(handle, 'entry'), isEmpty);
      await a.finish(handle);
      expect(calls.map((c) => c.method), [
        'syncBatchBegin',
        'syncBatchBind',
        'syncBatchSign',
        'syncBatchOpen',
        'syncBatchSkip',
        'syncBatchFinish',
      ]);
    },
  );
  test('malformed pending ids refused without finish/erase', () async {
    handler = (_) async => {
      'pending': ['entry', 'entry'],
    };
    await expectLater(
      adapter().skip(handle, 'entry'),
      failure(SeedSyncFailureKind.unknownOutcome),
    );
    expect(calls.length, 1);
  });
  test('invalid input has no native effects', () async {
    final a = adapter();
    await expectLater(
      a.enroll(owner: 'bad owner', installId: install, generation: 1),
      failure(SeedSyncFailureKind.invalidInput),
    );
    await expectLater(
      a.begin(
        owner: 'owner',
        deviceId: 'device',
        generation: 1,
        epoch: 0,
        entries: const [SeedBatchEntry('entry', 1, 'MD5', 6, 30)],
      ),
      failure(SeedSyncFailureKind.invalidInput),
    );
    await expectLater(
      a.finish('invalid'),
      failure(SeedSyncFailureKind.invalidInput),
    );
    expect(calls, isEmpty);
  });

  final methods = <String, Future<Object?> Function(SeedSyncChannel)>{
    'enroll': (a) => enroll(a),
    'erase': (a) =>
        a.erase(owner: 'owner', epoch: 0, reason: SeedEraseReason.disable),
    'begin': (a) => a.begin(
      owner: 'owner',
      deviceId: 'device',
      generation: 1,
      epoch: 0,
      entries: const [SeedBatchEntry('entry', 1, 'SHA-1', 6, 30)],
    ),
    'bind': (a) async {
      await a.bind(handle, challenge: install, expiresAt: 1000);
      return null;
    },
    'sign': (a) => a.signBatch(handle),
    'open': (a) => a.open(
      handle,
      entryId: 'entry',
      serverPublicKey: base64UrlEncode(pub).replaceAll('=', ''),
      nonce: base64UrlEncode(List.filled(12, 1)).replaceAll('=', ''),
      ciphertext: base64UrlEncode(List.filled(36, 1)).replaceAll('=', ''),
    ),
    'skip': (a) => a.skip(handle, 'entry'),
    'finish': (a) async {
      await a.finish(handle);
      return null;
    },
  };
  for (final entry in methods.entries) {
    test(
      '${entry.key} timeout, malformed reply, codec failure stay uncertain and do not replay',
      () async {
        for (final mode in ['timeout', 'malformed', 'codec']) {
          calls.clear();
          final held = Completer<Object?>();
          if (mode == 'timeout') handler = (_) => held.future;
          if (mode == 'malformed') handler = (_) async => 'malformed reply';
          if (mode == 'codec') {
            messenger.setMockMessageHandler(
              channel.name,
              (message) async =>
                  ByteData.sublistView(Uint8List.fromList([255])),
            );
          }
          await expectLater(
            entry.value(adapter(timeout: const Duration(milliseconds: 10))),
            failure(SeedSyncFailureKind.unknownOutcome),
          );
          if (mode != 'codec') expect(calls.length, 1);
          messenger.setMockMethodCallHandler(channel, (c) {
            calls.add(c);
            return handler(c);
          });
          if (mode == 'timeout') held.complete(null);
        }
      },
    );
  }
  test('erase incomplete is explicit non-purging failure, not retry', () async {
    handler = (_) async => throw PlatformException(code: 'ERASE_INCOMPLETE');
    await expectLater(
      adapter().erase(
        owner: 'owner',
        epoch: 0,
        reason: SeedEraseReason.disable,
      ),
      failure(SeedSyncFailureKind.eraseIncomplete),
    );
    expect(calls.length, 1);
  });
  test(
    'pending beyond native batch cap and oversize sealed input refused',
    () async {
      handler = (_) async => {
        'pending': ['a', 'b', 'c', 'd'],
      };
      await expectLater(
        adapter().skip(handle, 'a'),
        failure(SeedSyncFailureKind.unknownOutcome),
      );
      calls.clear();
      await expectLater(
        adapter().open(
          handle,
          entryId: 'a',
          serverPublicKey: 'A' * 1000,
          nonce: 'n',
          ciphertext: 'c',
        ),
        failure(SeedSyncFailureKind.invalidInput),
      );
      expect(calls, isEmpty);
    },
  );
}
