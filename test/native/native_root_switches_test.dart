import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_device_startup.dart';
import 'package:otpanda_client/native/native_root_io.dart';

void main() {
  test('entry edit and settings are separate switches, all off by default', () {
    expect(nativeEntryEditEnabled, isFalse);
    expect(nativeSettingsEnabled, isFalse);
    expect(nativeAuthEnabled, isFalse);
  });
}
