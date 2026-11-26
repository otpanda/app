import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_device_startup.dart';

void main() {
  test(
    'unqualified enrolled-device step-up stays off independently of sign-in',
    () {
      expect(nativeAuthEnabled, isFalse);
    },
  );
}
