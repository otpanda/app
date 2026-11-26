import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';

import 'browser_account_test.dart' show Bridge;

class SecurityBridge extends Bridge implements AuthEntryBridge, RealtimeBridge {
  @override
  String get email => "";
  @override
  String get pendingLabel => "";
  int checks = 0;
  int subscribed = 0, unsubscribed = 0;
  final listeners = <void Function(String)>[];
  @override
  void Function() realtimeSubscribe(void Function(String reason) listener) {
    subscribed++;
    listeners.add(listener);
    return () {
      unsubscribed++;
      listeners.remove(listener);
    };
  }

  void hint([String reason = 'changed']) {
    for (final l in [...listeners]) {
      l(reason);
    }
  }

  bool fail = false;
  List<Map<String, Object>> pending = [];
  Completer<String>? held;
  @override
  Future<String> security(
    String action, [
    bool enabled = false,
    String pendingId = '',
  ]) async {
    if (action != 'status') throw StateError('no automatic mutation');
    checks++;
    if (held != null) return held!.future;
    if (fail) throw StateError('offline');
    return jsonEncode({'enabled': true, 'pending': pending, 'changes': []});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ActionSecurityBridge extends SecurityBridge {
  Completer<void>? action;
  int overviewReads = 0;
  @override
  Future<SessionResponse> read(String path) async {
    if (path == '/v1/manage/account') {
      overviewReads++;
      return SessionResponse(
        200,
        jsonEncode({
          'email': 'fixture@example.test',
          'passkeys': 1,
          'google': true,
          'recoveryDevices': 0,
        }),
      );
    }
    return super.read(path);
  }

  @override
  Future<String> security(
    String kind, [
    bool enabled = false,
    String pendingId = '',
  ]) async {
    if (kind == 'deny') {
      await action?.future;
      pending = [];
      return '{}';
    }
    return super.security(kind, enabled, pendingId);
  }
}

Future<void> open(
  WidgetTester t,
  SecurityBridge b, [
  int Function()? clock,
]) async {
  await t.pumpWidget(
    MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        clock: clock ?? () => 100000,
        accountOnly: true,
        navigation: 'settings/account-security',
        loginEnabled: true,
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'security hints update the page at once; the 30s fallback is unchanged',
    (t) async {
      final b = SecurityBridge()
        ..status = 'restored'
        ..clockNow = 100000;
      await open(t, b);
      final base = b.checks;
      expect(
        base,
        1,
        reason: 'one first load, subscribed before it, no duplicate catch-up',
      );
      expect(b.subscribed, 1);
      expect(find.text('Check for sign-in requests'), findsNothing);
      b.pending = [
        {'pendingId': 'abcdef123', 'createdAt': 100000},
      ];
      await t.pump(const Duration(seconds: 20));
      expect(b.checks, base, reason: 'before the unchanged 30s fallback tick');
      b.hint();
      await t.pumpAndSettle();
      expect(b.checks, base + 1);
      expect(find.text('New-device sign-in request'), findsOneWidget);
      expect(find.text('Approve sign-in'), findsNothing);
      b.fail = true;
      b.hint();
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('New-device sign-in request'), findsOneWidget);
      b.fail = false;
      b.pending = [];
      b.hint('connect'); // reconnect closes the gap
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(find.text('New-device sign-in request'), findsNothing);
      final before = b.checks;
      b.hint('connection-lost');
      b.hint('connection-restored');
      await t.pumpAndSettle();
      expect(b.checks, before, reason: 'connection state alone reads nothing');
      await t.pumpWidget(const SizedBox());
      expect(b.unsubscribed, b.subscribed);
    },
  );
  testWidgets(
    'the existing 30s security fallback still reads once per interval with no hint',
    (t) async {
      final b = SecurityBridge()
        ..status = 'restored'
        ..clockNow = 100000;
      await open(t, b);
      final base = b.checks;
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(
        b.checks,
        base + 1,
        reason: 'unchanged fallback, not removed in this split',
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('hints coalesce to one in flight plus one trailing read', (
    t,
  ) async {
    final b = SecurityBridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await open(t, b);
    b.held = Completer<String>();
    for (var i = 0; i < 5; i++) {
      b.hint();
    }
    await t.pump(const Duration(seconds: 2));
    expect(b.checks, 2, reason: 'one in flight');
    final h = b.held!;
    b.held = null;
    h.complete(jsonEncode({'enabled': true, 'pending': [], 'changes': []}));
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(b.checks, 3, reason: 'exactly one trailing read');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('a request disappears at its own expiresAt without any request', (
    t,
  ) async {
    var now = 100000;
    final b = SecurityBridge()
      ..status = 'restored'
      ..clockNow = 100000
      ..pending = [
        {'pendingId': 'abcdef123', 'createdAt': 100000, 'expiresAt': 130000},
      ];
    await open(t, b, () => now);
    expect(find.text('New-device sign-in request'), findsOneWidget);
    now = 130001;
    await t.pump(const Duration(seconds: 2));
    expect(find.text('New-device sign-in request'), findsNothing);
    expect(b.checks, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'leaving the page unsubscribes, entering reads once and listens',
    (t) async {
      final b = SecurityBridge()
        ..status = 'restored'
        ..clockNow = 100000;
      await open(t, b);
      await t.tap(find.text('Devices & sessions'));
      await t.pumpAndSettle();
      expect(b.listeners, isEmpty);
      final before = b.checks;
      b.hint();
      await t.pump(const Duration(seconds: 20));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(b.checks, before, reason: 'nothing offscreen');
      await t.tap(find.text('Account & security'));
      await t.pumpAndSettle();
      expect(b.checks, before + 1, reason: 'entry reads once');
      expect(b.listeners.length, 1);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('a hint during the very first read is not lost', (t) async {
    final b = SecurityBridge()
      ..status = 'restored'
      ..clockNow = 100000
      ..held = Completer<String>();
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          clock: () => 100000,
          accountOnly: true,
          navigation: 'settings/account-security',
          loginEnabled: true,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(b.checks, 1);
    expect(b.listeners.length, 1, reason: 'subscribed before the read');
    b.hint();
    final h = b.held!;
    b.held = null;
    h.complete(jsonEncode({'enabled': true, 'pending': [], 'changes': []}));
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(b.checks, 2, reason: 'exactly one trailing read for the hint');
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('a page shown before status is restored subscribes on restore', (
    t,
  ) async {
    final b = SecurityBridge()
      ..status = 'authenticating'
      ..clockNow = 100000;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          clock: () => 100000,
          accountOnly: true,
          navigation: 'settings/account-security',
          loginEnabled: true,
        ),
      ),
    );
    await t.pump(
      const Duration(milliseconds: 100),
    ); // bounded: a spinner never settles
    expect(b.listeners, isEmpty, reason: 'not restored yet');
    b.status = 'restored';
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(milliseconds: 100));
    expect(b.listeners.length, 1, reason: 'subscribed on the transition');
    await t.pumpWidget(const SizedBox());
    expect(b.unsubscribed, b.subscribed);
  });
  testWidgets(
    'a hint while a user action runs gets one quiet overview catch-up',
    (t) async {
      t.view.physicalSize = const Size(1280, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final b = ActionSecurityBridge()
        ..status = 'restored'
        ..clockNow = 100000
        ..pending = [
          {'pendingId': 'abcdef123', 'createdAt': 100000},
        ];
      await open(t, b);
      final before = b.overviewReads;
      b.action = Completer<void>();
      await t.ensureVisible(find.text('Deny'));
      await t.tap(find.text('Deny'));
      await t.pump();
      b.hint();
      await t.pump(const Duration(milliseconds: 100));
      expect(
        b.overviewReads,
        before,
        reason: 'no overlapping overview during the user action',
      );
      b.action!.complete();
      await t.pumpAndSettle();
      expect(
        b.overviewReads,
        before + 2,
        reason: 'action refresh plus exactly one queued quiet catch-up',
      );
      expect(find.text('New-device sign-in request'), findsNothing);
      final after = b.overviewReads;
      await t.pump(const Duration(seconds: 20));
      expect(
        b.overviewReads,
        after,
        reason: 'no extra overview read after the single catch-up',
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('late status cannot reappear after signout', (t) async {
    final b = SecurityBridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await open(t, b);
    b.held = Completer<String>();
    b.hint();
    await t.pump(const Duration(seconds: 2));
    b.logout();
    b.held!.complete(
      jsonEncode({
        'enabled': true,
        'pending': [
          {'pendingId': 'abcdef123', 'createdAt': 100000},
        ],
        'changes': [],
      }),
    );
    await t.pumpAndSettle();
    expect(find.text('New-device sign-in request'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
