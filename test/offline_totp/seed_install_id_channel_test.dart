import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_install_id.dart';
import 'package:otpanda_client/offline_totp/seed_install_id_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('inactive-install-id');
  final calls = <MethodCall>[];
  bool unreadable = false;
  setUp(() {
    unreadable = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (unreadable) {
            throw PlatformException(code: 'INSTALL_ID_UNREADABLE');
          }
          return switch (call.method) {
            'syncInstallIdGet' => {'installId': null},
            'syncInstallIdEnsure' => {'installId': 'W' * 43, 'created': false},
            _ => throw MissingPluginException(),
          };
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'exact contract uses returned winner, one creation for concurrent callers',
    () async {
      final id = SeedInstallId(SeedInstallIdChannelStore(channel));
      final values = await Future.wait([id.get(), id.get()]);
      expect(values, ['W' * 43, 'W' * 43]);
      expect(calls.map((c) => c.method), [
        'syncInstallIdGet',
        'syncInstallIdEnsure',
      ]);
      expect(calls.first.arguments, isEmpty);
      expect((calls.last.arguments as Map).keys, ['installId']);
      expect(
        (calls.last.arguments as Map)['installId'],
        matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
      );
    },
  );
  test('unreadable never ensures or overwrites, later retry allowed', () async {
    final id = SeedInstallId(SeedInstallIdChannelStore(channel));
    unreadable = true;
    await expectLater(
      id.get(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'INSTALL_ID_UNREADABLE',
        ),
      ),
    );
    expect(calls.length, 1);
    unreadable = false;
    expect(await id.get(), 'W' * 43);
  });
  test(
    'mismatch is propagated without ensure, erase or cached replacement',
    () async {
      final id = SeedInstallId(SeedInstallIdChannelStore(channel));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'INSTALL_ID_MISMATCH');
          });
      for (var n = 0; n < 2; n++) {
        await expectLater(
          id.get(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'INSTALL_ID_MISMATCH',
            ),
          ),
        );
      }
      expect(calls.map((c) => c.method), [
        'syncInstallIdGet',
        'syncInstallIdGet',
      ]);
    },
  );
}
