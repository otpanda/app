import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_enrollment.dart';

class Bridge implements BrowserSessionBridge, TotpManagementBridge {
  int adds = 0, reads = 0;
  bool fail = false;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<String> addTotp(
    String label,
    String account,
    String secret, {
    String? catalogId,
  }) async {
    adds++;
    if (fail) throw const ClientFailure();
    return 'entry';
  }

  @override
  Future<SessionResponse> read(String path) async => SessionResponse(
    200,
    jsonEncode({
      'ownerId': 'owner',
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
    }),
  );
  @override
  Future<SessionResponse> totpCode(String entryId) async {
    reads++;
    final now = DateTime.now().millisecondsSinceEpoch,
        start = now ~/ 30000 * 30;
    return SessionResponse(
      200,
      jsonEncode({
        'entryId': entryId,
        'code': '123456',
        'period': 30,
        'validFrom': start,
        'validUntil': start + 30,
        'serverNow': now,
      }),
    );
  }
}

void main() {
  qrTests();
  testWidgets(
    'missing passkey routes to account settings before secret entry',
    (t) async {
      final bridge = MissingPasskeyBridge();
      var opened = false;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async {
                await totpPrerequisite(c, bridge, () => opened = true);
              },
              child: const Text('Start'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Start'));
      await t.pumpAndSettle();
      expect(find.text('Add a passkey first'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.text('Account & security'));
      await t.pumpAndSettle();
      expect(opened, isTrue);
      expect(bridge.adds, 0);
    },
  );
  testWidgets(
    'enrollment validates, hides secret and requires explicit verification',
    (t) async {
      final bridge = Bridge();
      String? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async {
                result = await addTotpDialog(
                  c,
                  bridge,
                  camera: (_, _) => const SizedBox.expand(),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Enter key manually'));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
      await t.enterText(find.byType(TextField), 'SYNTHETICKEY');
      await t.pump();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
            .onPressed,
        isNull,
      );
      await t.enterText(find.byType(TextField), 'jbsw y3dp ehpk 3pxp');
      await t.pump();
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      await t.tap(find.text('Verify and add'));
      await t.pump();
      expect(bridge.adds, 0);
      expect(find.text('Enter a name.'), findsOneWidget);
      await t.enterText(find.byType(TextField).at(0), 'Example');
      await t.tap(find.text('Verify and add'));
      await t.pumpAndSettle();
      expect(bridge.adds, 1);
      expect(result, 'entry');
    },
  );
  testWidgets('generated code loads automatically and clears on background', (
    t,
  ) async {
    final bridge = Bridge();
    await t.pumpWidget(
      MaterialApp(
        home: TotpEntryDialog(bridge: bridge, entryId: 'entry'),
      ),
    );
    await t.pump();
    await t.pump();
    expect(bridge.reads, 1);
    expect(find.text('123456'), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(find.text('123456'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    await t.pump();
    expect(bridge.reads, 2);
    await t.pumpWidget(const SizedBox());
  });
}

class MissingPasskeyBridge extends Bridge {
  @override
  Future<SessionResponse> read(String path) async =>
      const SessionResponse(200, '{"passkeys":0}');
}

void qrTests() {}
