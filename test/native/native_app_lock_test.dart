import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_app_lock.dart';
import 'package:otpanda_client/native/native_navigation.dart';

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
  testWidgets(
    'actual MaterialApp builder lock blocks hidden dialog and account history Back',
    (t) async {
      final p = Fake()..saved = true;
      final c = LocalLockController(p);
      final h = NativeNavigationHistory();
      final observer = LockNavigationObserver(c);
      c.addListener(() => h.blocked = !c.ready || c.locked);
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [observer],
          builder: (context, child) =>
              NativeAppLock(controller: c, child: child!),
          home: NativeNavigation(
            history: h,
            builder: (context, route, navigate) => Scaffold(body: Text(route)),
          ),
        ),
      );
      await t.pump();
      await c.unlock();
      await t.pump();
      h.navigate('settings');
      await t.pump();
      showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const AlertDialog(content: Text('hidden-dialog')),
      );
      await t.pumpAndSettle();
      c.background();
      await t.pump();
      await t.binding.handlePopRoute();
      await t.pump();
      expect(h.route, 'settings');
      expect(nav.currentState!.canPop(), true);
      c.resume();
      await c.unlock();
      await t.pumpAndSettle();
      expect(find.text('hidden-dialog'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(h.route, 'settings');
      c.background();
      await t.pump();
      await t.binding.handlePopRoute();
      await t.pump();
      expect(h.route, 'settings');
      c.resume();
      await c.unlock();
      await t.pump();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(h.route, 'codes');
      await t.pumpWidget(const SizedBox());
      observer.dispose();
      h.dispose();
      c.dispose();
    },
  );

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
      final observer = LockNavigationObserver(c);
      addTearDown(observer.dispose);
      await t.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          builder: (context, child) =>
              NativeAppLock(controller: c, child: child!),
          home: const Scaffold(body: Text('private-code')),
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
