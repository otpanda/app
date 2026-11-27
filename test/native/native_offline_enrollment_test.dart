import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_offline_enrollment.dart';
import 'package:otpanda_client/offline_totp/seed_enrollment_coordinator.dart';
import 'package:otpanda_client/offline_totp/seed_sync_channel.dart';

import '../offline_totp/fake_seed_custody.dart';
import '../offline_totp/seed_enrollment_coordinator_test.dart'
    show FakeNative, FakeApi, FakePasskey;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'setup is explicit, confirmation does not claim downloaded codes',
    () async {
      final native = FakeNative(), api = FakeApi(), passkey = FakePasskey();
      var current = true;
      final c = NativeOfflineEnrollment(
        enrollment: SeedEnrollmentCoordinator(
          native: native,
          api: api,
          passkey: passkey,
          isCurrent: (_) async => current,
        ),
        custody: FakeSeedCustody(),
        sync: SeedSyncChannel(const MethodChannel('unused')),
        isCurrent: (_) async => current,
        installId: () async => 'I' * 43,
      );
      c.bindOwner('owner');
      expect(api.calls, isEmpty);
      expect(native.calls, isEmpty);
      await c.setUp();
      expect(c.confirmed, true);
      expect(c.message, contains('must finish downloading'));
      current = false;
      final count = api.calls.length;
      await c.setUp();
      expect(api.calls.length, count);
      c.dispose();
    },
  );
  test('owner change during install lookup cannot launch enrollment', () async {
    final pending = Completer<String>();
    final native = FakeNative(), api = FakeApi();
    final c = NativeOfflineEnrollment(
      enrollment: SeedEnrollmentCoordinator(
        native: native,
        api: api,
        passkey: FakePasskey(),
        isCurrent: (_) async => true,
      ),
      custody: FakeSeedCustody(),
      sync: SeedSyncChannel(const MethodChannel('unused')),
      isCurrent: (_) async => true,
      installId: () => pending.future,
    );
    c.bindOwner('owner');
    final run = c.setUp();
    await Future<void>.delayed(Duration.zero);
    c.bindOwner('other');
    pending.complete('I' * 43);
    await run;
    expect(api.calls, isEmpty);
    expect(c.confirmed, false);
    expect(c.message, isNull);
    c.dispose();
  });
}
