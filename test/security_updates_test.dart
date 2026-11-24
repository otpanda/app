import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';

import 'browser_account_test.dart' show Bridge;

class SecurityBridge extends Bridge implements AuthEntryBridge {
  @override
  String get email => "";
  @override
  String get pendingLabel => "";
  int checks = 0;
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

void main() {
  testWidgets(
    'security automatically checks, retries and resumes without approval',
    (t) async {
      final b = SecurityBridge()
        ..status = 'restored'
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
      await t.pumpAndSettle();
      expect(b.checks, 1);
      expect(find.text('Check for sign-in requests'), findsNothing);
      b.pending = [
        {'pendingId': 'abcdef123', 'createdAt': 100000},
      ];
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(find.text('New-device sign-in request'), findsOneWidget);
      expect(find.text('Approve sign-in'), findsNothing);
      b.fail = true;
      await t.pump(const Duration(seconds: 31));
      await t.pumpAndSettle();
      expect(find.text('New-device sign-in request'), findsOneWidget);
      b.fail = false;
      b.pending = [];
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.text('New-device sign-in request'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('late status cannot reappear after signout', (t) async {
    final b = SecurityBridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          clock: () => 100000,
          navigation: 'settings/account-security',
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    b.held = Completer<String>();
    await t.pump(const Duration(seconds: 31));
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
