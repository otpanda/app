import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/android_seed_custody.dart';
import 'package:otpanda_client/offline_totp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('custody-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidSeedCustody custody;
  setUp(() {
    custody = AndroidSeedCustody(channel: channel);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('owner state is strict, read-only metadata', () async {
    messenger.setMockMethodCallHandler(channel, (c) async {
      expect(c.method, 'readOwnerState');
      expect(c.arguments, {'owner': 'owner'});
      return {'epoch': 4, 'enabled': false};
    });
    final state = await custody.readOwnerState('owner');
    expect(state.epoch, 4);
    expect(state.enabled, false);
    for (final value in [
      {'epoch': -1, 'enabled': true},
      {'epoch': 1.5, 'enabled': true},
      {'epoch': 0, 'enabled': 'true'},
      {'epoch': 0, 'enabled': true, 'extra': 0},
    ]) {
      messenger.setMockMethodCallHandler(channel, (c) async => value);
      await expectLater(
        custody.readOwnerState('owner'),
        throwsA(isA<CustodyException>()),
      );
    }
  });
  test('measured software protection is not upgraded to hardware', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (c) async => {'protection': 'OS_ENCRYPTED', 'reason': null},
    );
    expect(
      (await custody.capability()).protection,
      CustodyProtection.osEncrypted,
    );
  });
  test('provision exact wire shape and caller bytes preserved', () async {
    final seed = Uint8List.fromList(List.filled(20, 1));
    messenger.setMockMethodCallHandler(channel, (c) async {
      expect(c.method, 'provision');
      expect((c.arguments as Map).keys.toSet(), {
        'owner',
        'entry',
        'seedVersion',
        'algorithm',
        'digits',
        'periodSeconds',
        'seed',
        'epoch',
      });
      expect(c.arguments['algorithm'], 'sha256');
      expect(c.arguments['seed'], seed);
      return null;
    });
    await custody.provision(
      ownerId: 'owner',
      entryId: 'entry',
      seedVersion: 1,
      algorithm: OtpAlgorithm.sha256,
      digits: 8,
      period: 30,
      seed: seed,
      epoch: 0,
    );
    expect(seed, everyElement(1));
  });
  test('all platform errors map without private diagnostic text', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (c) async => throw PlatformException(
        code: 'METADATA_UNAVAILABLE',
        message: 'private',
      ),
    );
    await expectLater(
      custody.clearOwner('owner', epoch: 0),
      throwsA(
        isA<CustodyException>().having(
          (e) => e.error,
          'error',
          CustodyError.metadataUnavailable,
        ),
      ),
    );
  });
  test('malformed and unknown native answers fail closed', () async {
    for (final answer in [
      null,
      {'protection': 'HARDWARE', 'reason': null},
      {'protection': 'OS_ENCRYPTED', 'reason': null, 'seed': 'x'},
    ]) {
      messenger.setMockMethodCallHandler(channel, (c) async => answer);
      await expectLater(custody.capability(), throwsA(isA<CustodyException>()));
    }
  });
  test('clear requires durable denied flag, not just purged', () async {
    for (final denied in [false, null]) {
      messenger.setMockMethodCallHandler(
        channel,
        (c) async => {'denied': denied, 'purged': true},
      );
      await expectLater(
        custody.clearOwner('owner', epoch: 0),
        throwsA(isA<CustodyException>()),
      );
    }
    messenger.setMockMethodCallHandler(
      channel,
      (c) async => {'denied': true, 'purged': false},
    );
    expect((await custody.clearOwner('owner', epoch: 0)).purged, false);
  });
  test('generate never accepts non-code or empty answers', () async {
    for (final answer in ['', null, 123456, '12345', '123456789', 'seed']) {
      messenger.setMockMethodCallHandler(channel, (c) async => answer);
      await expectLater(
        custody.generate(
          ownerId: 'owner',
          entryId: 'entry',
          seedVersion: 1,
          unixSeconds: 59,
        ),
        throwsA(isA<CustodyException>()),
      );
    }
    messenger.setMockMethodCallHandler(channel, (c) async => '012345');
    expect(
      await custody.generate(
        ownerId: 'owner',
        entryId: 'entry',
        seedVersion: 1,
        unixSeconds: 59,
      ),
      '012345',
    );
  });
}
