import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_app_lock.dart';

class Fake implements LocalLockPlatform {
  bool saved = false, allow = true, fail = false;
  int checks = 0, writes = 0;
  Completer<bool>? prompt;
  @override
  Future<bool> enabled() async {
    if (fail) throw StateError('failed');
    return saved;
  }

  @override
  Future<bool> verify() async {
    checks++;
    return prompt?.future ?? allow;
  }

  @override
  Future<void> setEnabled(bool value) async {
    writes++;
    saved = value;
  }
}

void main() {
  test(
    'OS prompt may pause app and finish before resumed without deadlock',
    () async {
      final p = Fake()..saved = true;
      final c = LocalLockController(p);
      await c.load();
      p.prompt = Completer<bool>();
      final f = c.unlock();
      c.background();
      p.prompt!.complete(true);
      await f;
      expect(c.locked, true);
      c.resume();
      expect(c.locked, false);
      c.background();
      expect(c.locked, true);
    },
  );
  test('async verification completion after dispose is ignored', () async {
    final p = Fake()..saved = true;
    final c = LocalLockController(p);
    await c.load();
    p.prompt = Completer<bool>();
    final f = c.unlock();
    c.dispose();
    p.prompt!.complete(true);
    await f;
  });

  test(
    'off by default, enable and disable each require fresh verification',
    () async {
      final p = Fake(), c = LocalLockController(p);
      await c.load();
      expect(c.enabled, false);
      expect(c.locked, false);
      await c.change(true);
      expect(c.enabled, true);
      expect(p.checks, 1);
      c.background();
      expect(c.locked, true);
      p.allow = false;
      await c.unlock();
      expect(c.locked, true);
      await c.change(false);
      expect(c.enabled, true);
      expect(p.writes, 1);
      p.allow = true;
      c.foreground = true;
      await c.unlock();
      expect(c.locked, false);
      await c.change(false);
      expect(c.enabled, false);
      expect(p.checks, 5);
    },
  );
  test(
    'cold enabled starts locked; failed settings read fails closed',
    () async {
      final p = Fake()..saved = true;
      final c = LocalLockController(p);
      await c.load();
      expect(c.locked, true);
      final bad = LocalLockController(Fake()..fail = true);
      await bad.load();
      expect(bad.ready, false);
      expect(bad.locked, true);
    },
  );
  testWidgets(
    'enabled cold and lifecycle lock hide sensitive child without disposing it',
    (t) async {
      final p = Fake()..saved = true;
      final c = LocalLockController(p);
      await t.pumpWidget(
        MaterialApp(
          home: NativeAppLock(
            controller: c,
            child: const Scaffold(body: Text('private-code')),
          ),
        ),
      );
      await t.pump();
      expect(find.text('private-code'), findsNothing);
      await t.tap(find.text('Device unlock'));
      await t.pumpAndSettle();
      expect(find.text('private-code'), findsOneWidget);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      expect(find.text('private-code'), findsNothing);
      await t.binding.handlePopRoute();
      await t.pump();
      expect(find.text('OTPanda is locked'), findsOneWidget);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(find.text('private-code'), findsNothing);
    },
  );
}
