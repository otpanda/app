import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_app_lock.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_local_lock_session.dart';

class _Platform implements LocalLockPlatform {
  @override
  Future<bool> enabled() async => true;
  @override
  Future<bool> verify() async => true;
  @override
  Future<void> setEnabled(bool value) async {}
}

void main() {
  test(
    'rotating access does not relock; device change and signout do',
    () async {
      final c = LocalLockController(_Platform());
      final boundary = NativeLocalLockSessionBoundary();
      void observe(NativeSession? s, {bool signedOut = false}) {
        if (boundary.update(s?.deviceId, signedOut: signedOut)) {
          c.sessionChanged();
        }
      }

      await c.load();
      observe(const NativeSession('device1', 'old-access', 1000));
      await c.unlock();
      final generation = c.lockGeneration;
      expect(c.locked, false);
      observe(null); // Unknown/offline transients are not a sign-out.
      expect(c.locked, false);
      expect(c.lockGeneration, generation);
      observe(const NativeSession('device1', 'renewed-access', 2000));
      expect(c.locked, false);
      expect(c.lockGeneration, generation);
      observe(const NativeSession('device2', 'new-device-access', 2000));
      expect(c.locked, true);
      expect(c.lockGeneration, isNot(generation));
      await c.unlock();
      observe(null, signedOut: true);
      expect(c.locked, true);
      c.dispose();
    },
  );
}
