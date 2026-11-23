import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge implements BrowserSessionBridge {
  @override
  String status = 'idle';
  int reads = 0, prompts = 0, logouts = 0;
  bool denied = false;
  @override
  Future<void> get ready async {}
  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {
    prompts++;
    status = 'sign-in-required';
  }

  @override
  void clear() {
    status = 'idle';
  }

  @override
  void logout() {
    logouts++;
    status = 'idle';
  }

  @override
  Future<SessionResponse> read(String path) async {
    reads++;
    if (denied) {
      status = 'sign-in-required';
      return const SessionResponse(401, '{}');
    }
    return SessionResponse(
      200,
      jsonEncode(switch (path) {
        '/v1/manage/session' => {
          'ownerId': 'synthetic',
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
        },
        '/v1/manage/entries' => {'entries': []},
        _ => {'records': []},
      }),
    );
  }
}

void main() {
  testWidgets('disabled connection is separate and does not launch auth', (
    t,
  ) async {
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: Bridge())));
    await t.pumpAndSettle();
    expect(find.textContaining('not enabled'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sign in with passkey'),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'restored session loads once, refreshes once and clears honestly',
    (t) async {
      final b = Bridge()..status = 'restored';
      await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
      await t.pumpAndSettle();
      expect(b.reads, 3);
      await t.tap(find.text('Refresh real codes'));
      await t.pumpAndSettle();
      expect(b.reads, 6);
      await t.tap(find.text('Clear local access'));
      await t.pumpAndSettle();
      expect(find.textContaining('does not revoke'), findsOneWidget);
      expect(find.text('Browser session available.'), findsNothing);
    },
  );
  testWidgets('passkey cancellation has retry status and no code reads', (
    t,
  ) async {
    final b = Bridge()..status = 'passkey-ready';
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
    await t.pumpAndSettle();
    await t.tap(find.text('Use passkey'));
    await t.pumpAndSettle();
    expect(b.prompts, 1);
    expect(b.reads, 0);
    expect(find.textContaining('did not finish'), findsOneWidget);
  });
  testWidgets('401 stops real data load and updates status', (t) async {
    final b = Bridge()
      ..status = 'restored'
      ..denied = true;
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
    await t.pumpAndSettle();
    expect(b.reads, 1);
    expect(find.text('Browser session available.'), findsNothing);
  });
  testWidgets(
    'server signout distinct from local clear and disabled until enabled',
    (t) async {
      final b = Bridge()..status = 'restored';
      await t.pumpWidget(
        MaterialApp(home: BrowserAccountPage(bridge: b, loginEnabled: true)),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Sign out of this browser'));
      await t.pumpAndSettle();
      expect(b.logouts, 1);
      expect(b.status, 'idle');
      expect(find.text('Browser session available.'), findsNothing);
    },
  );
}
