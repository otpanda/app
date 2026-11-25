import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('t/dl');
  Future<void> reply(Object? Function() f) async =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (c) async => f());
  test('trims, caps at 40, null on empty/error/missing', () async {
    await reply(() => '  Abraham\'s Pixel 8a ');
    expect(await androidDeviceLabel(channel: ch), "Abraham's Pixel 8a");
    await reply(() => 'x' * 60);
    expect((await androidDeviceLabel(channel: ch))!.length, 40);
    await reply(() => '${'a' * 39}😀😀');
    expect((await androidDeviceLabel(channel: ch))!.runes.length, 40);
    await reply(() => '  ');
    expect(await androidDeviceLabel(channel: ch), isNull);
    await reply(() => throw PlatformException(code: 'e'));
    expect(await androidDeviceLabel(channel: ch), isNull);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
    expect(await androidDeviceLabel(channel: ch), isNull);
  });
}
