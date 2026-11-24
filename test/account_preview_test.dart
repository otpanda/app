import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/account_preview.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';

class RouterBridge implements BrowserSessionBridge {
  @override
  final String status;
  final Completer<void> gate = Completer<void>();
  RouterBridge(this.status);
  @override
  Future<void> get ready => gate.future;
  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {}
  @override
  void clear() {}
  @override
  void logout() {}
  @override
  Future<SessionResponse> read(String path) async =>
      const SessionResponse(401, '{}');
  @override
  Future<SessionResponse> organize(String method, String body) async =>
      const SessionResponse(401, '{}');
  @override
  Future<SessionResponse> copied(String id, int at) async =>
      const SessionResponse(401, '{}');
}

void main() {
  for (final status in [
    'signup-ready',
    'passkey-ready',
    'restored',
    'sign-in-required',
    'check-clock-or-restart',
  ]) {
    testWidgets('callback $status resumes account-only page exactly once', (
      tester,
    ) async {
      final bridge = RouterBridge(status);
      await tester.pumpWidget(
        MaterialApp(home: AccountEntryRouter(bridge: bridge)),
      );
      bridge.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserAccountPage), findsOneWidget);
      final page = tester.widget<BrowserAccountPage>(
        find.byType(BrowserAccountPage),
      );
      expect(page.bridge, same(bridge));
      expect(page.loginEnabled && page.accountOnly, isTrue);
      expect(page.assignmentEnabled, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserAccountPage), findsNothing);
      expect(find.text('Your codes'), findsOneWidget);
    });
  }
  for (final status in ['idle', 'unsupported']) {
    testWidgets('ordinary $status visit keeps fictional workspace', (
      tester,
    ) async {
      final bridge = RouterBridge(status);
      await tester.pumpWidget(
        MaterialApp(home: AccountEntryRouter(bridge: bridge)),
      );
      bridge.gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserAccountPage), findsNothing);
      expect(find.text('Your codes'), findsOneWidget);
    });
  }
  testWidgets('disposed router never opens account route', (tester) async {
    final bridge = RouterBridge('signup-ready');
    await tester.pumpWidget(
      MaterialApp(home: AccountEntryRouter(bridge: bridge)),
    );
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    bridge.gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(BrowserAccountPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'account action opens enabled auth-only account page, not preview setup',
    (tester) async {
      await tester.pumpWidget(const OTPandaApp());
      await tester.tap(find.byTooltip('Account & security'));
      await tester.pumpAndSettle();
      expect(find.text('Your account'), findsOneWidget);
      final page = tester.widget<BrowserAccountPage>(
        find.byType(BrowserAccountPage),
      );
      expect(page.loginEnabled, isTrue);
      expect(page.accountOnly, isTrue);
      expect(page.assignmentEnabled, isFalse);
      expect(find.byType(AccountSecurityPreview), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Your codes'), findsOneWidget);
    },
  );
  testWidgets(
    'sample readiness and last-option warning do not claim enrollment',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AccountSecurityPreview()),
      );
      expect(find.text('At risk of losing access'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Include a sample passkey'),
        250,
      );
      await tester.tap(find.text('Include a sample passkey'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('One example recovery option'),
        -250,
      );
      expect(find.text('One example recovery option'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Include a sample passkey'),
        250,
      );
      await tester.tap(find.text('Include a sample passkey'));
      await tester.pumpAndSettle();
      expect(find.text('No recovery option left'), findsOneWidget);
      await tester.tap(find.text('Keep option'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isTrue,
      );
      await tester.tap(find.text('Include a sample passkey'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove in preview'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isFalse,
      );
    },
  );
  testWidgets('small screen security preview and warning stay usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: AccountSecurityPreview()));
    await tester.scrollUntilVisible(
      find.text('Include a sample Android device'),
      200,
    );
    await tester.ensureVisible(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Keep option'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
