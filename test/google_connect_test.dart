import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/auth_entry.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/google_link.dart';

import 'google_account_action_test.dart' show GoogleBridge;

class ConnectBridge extends GoogleBridge implements GoogleConnectBridge {
  String reason = '';
  String result = '';
  int connects = 0, clears = 0;
  @override
  bool get googleConnectAvailable => true;
  @override
  Future<String> connectGoogle() async {
    connects++;
    return reason;
  }

  @override
  String takeGoogleLinkResult() {
    final r = result;
    result = '';
    return r;
  }

  @override
  void clear() {
    clears++;
    super.clear();
  }
}

class LinkOnlyBridge implements BrowserSessionBridge, AuthEntryBridge {
  final actions = <String>[];
  @override
  String get email => 'a@example.test';
  @override
  Future<void> googleContinue(String action, [String proof = '']) async {
    actions.add(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> open(WidgetTester t, GoogleBridge b) async {
  await t.pumpWidget(
    MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        accountOnly: true,
        loginEnabled: true,
        navigation: 'settings/account-security',
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Connect uses the signed-in connect, never sign-in or clear', (
    t,
  ) async {
    final b = ConnectBridge()..status = 'restored';
    await open(t, b);
    await t.tap(find.text('Connect'));
    await t.pump(const Duration(milliseconds: 100));
    expect(b.connects, 1);
    expect(b.starts, isEmpty);
    expect(b.clears, 0);
    expect(b.status, 'restored');
    await t.pumpWidget(const SizedBox());
  });

  for (final c in {
    'already_linked': 'Google is already connected.',
    'no_passkey': 'Add a passkey first, then you can connect Google.',
    'retry': 'Too many tries. Wait a little and try again.',
    'signin': 'Browser access expired. Sign in again.',
    'unavailable': 'Could not start Google. Try again.',
  }.entries) {
    testWidgets('connect refusal ${c.key} shows a message and stays here', (
      t,
    ) async {
      final b = ConnectBridge()
        ..status = 'restored'
        ..reason = c.key;
      await open(t, b);
      await t.tap(find.text('Connect'));
      await t.pumpAndSettle();
      expect(find.text(c.value), findsOneWidget);
      expect(b.starts, isEmpty);
      expect(b.clears, 0);
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Connect'),
            )
            .onPressed,
        isNotNull,
      );
      await t.pumpWidget(const SizedBox());
    });
  }

  for (final r in {
    'connected': 'Google connected.',
    'restart': 'Google was not connected. Try again.',
    'mismatch': "That Google account does not use this account's email, so it was not connected.",
  }.entries) {
    testWidgets('returning with result ${r.key} shows it once', (t) async {
      final b = ConnectBridge()
        ..status = 'restored'
        ..linked = r.key == 'connected'
        ..result = r.key;
      await open(t, b);
      expect(find.text(r.value), findsOneWidget);
      expect(b.result, '');
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('without a connect bridge there is no Connect and no sign-in', (
    t,
  ) async {
    final b = GoogleBridge()..status = 'restored';
    await open(t, b);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(b.starts, isEmpty);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a connected notice never overrides the overview', (t) async {
    final b = ConnectBridge()
      ..status = 'restored'
      ..result = 'connected';
    await open(t, b);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Google connected.'), findsNothing);
    expect(
      find.text('Could not confirm that Google is connected. Check below.'),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a connected notice with a connected overview confirms it', (
    t,
  ) async {
    final b = ConnectBridge()
      ..status = 'restored'
      ..linked = true
      ..result = 'connected';
    await open(t, b);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Google connected.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('link-only screen verifies with a passkey or cancels', (t) async {
    final b = LinkOnlyBridge();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthEntry(
            bridge: b,
            status: 'google-link-only',
            message: '',
            busy: false,
            run: (f) => f(),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Connect Google.'), findsOneWidget);
    expect(find.textContaining('You stay signed in'), findsOneWidget);
    expect(find.text('Use another sign-in method'), findsNothing);
    await t.tap(find.text('Verify with passkey'));
    await t.pump();
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(b.actions, ['link-only', 'link-cancel']);
  });
}
