import 'package:otpanda_client/transfer/import_review.dart';
import 'package:otpanda_client/offline_totp/google_migration.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';

import 'dart:typed_data';
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

class BatchSaver implements ImportSaver {
  int calls = 0;
  @override
  bool get atomic => true;
  @override
  Future<ImportSaveOutcome> save(List<OtpAccount> a) async {
    calls++;
    return ImportSaveOutcome.saved;
  }
}

void main() {
  qrTests();
  testWidgets(
    'existing add scanner auto-dispatches Google export to whole batch review',
    (t) async {
      final bridge = Bridge(), saver = BatchSaver();
      void Function(String)? scan;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => addTotpDialog(
                c,
                bridge,
                importSaver: saver,
                camera: (onText, onError) {
                  scan = onText;
                  return const SizedBox();
                },
              ),
              child: const Text('Add'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Add'));
      await t.pumpAndSettle();
      final a = OtpAccount(
        issuer: null,
        accountName: 'synthetic',
        secret: Uint8List.fromList(List.filled(20, 42)),
      );
      scan!(encodeMigrationUris([a], batchId: 77).single);
      await t.pumpAndSettle();
      expect(find.text('Review import'), findsOneWidget);
      expect(saver.calls, 0);
      expect(bridge.adds, 0);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(saver.calls, 0);
      expect(bridge.adds, 0);
    },
  );

  testWidgets(
    'scanner saves batch and returns refresh signal without single enrollment',
    (t) async {
      final bridge = Bridge(), saver = BatchSaver();
      void Function(String)? scan;
      String? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async {
                result = await addTotpDialog(
                  c,
                  bridge,
                  importSaver: saver,
                  camera: (onText, onError) {
                    scan = onText;
                    return const SizedBox();
                  },
                );
              },
              child: const Text('Add'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Add'));
      await t.pumpAndSettle();
      scan!(
        encodeMigrationUris([
          OtpAccount(
            issuer: null,
            accountName: 'synthetic',
            secret: Uint8List.fromList(List.filled(20, 42)),
          ),
        ], batchId: 78).single,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Import 1 account'));
      await t.pumpAndSettle();
      await t.tap(find.text('Got it'));
      await t.pumpAndSettle();
      expect(saver.calls, 1);
      expect(bridge.adds, 0);
      expect(result, '');
    },
  );

  testWidgets(
    'scanner marks owned issuer/account matches as possible duplicates',
    (t) async {
      final bridge = Bridge(), saver = BatchSaver();
      void Function(String)? scan;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () => addTotpDialog(
                c,
                bridge,
                importSaver: saver,
                existingImports: {(null, 'synthetic')},
                camera: (onText, onError) {
                  scan = onText;
                  return const SizedBox();
                },
              ),
              child: const Text('Add'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Add'));
      await t.pumpAndSettle();
      scan!(
        encodeMigrationUris([
          OtpAccount(
            issuer: null,
            accountName: 'synthetic',
            secret: Uint8List.fromList(List.filled(20, 42)),
          ),
        ], batchId: 79).single,
      );
      await t.pumpAndSettle();
      expect(find.textContaining('possible duplicate'), findsWidgets);
      expect(find.text('Import 0 accounts'), findsOneWidget);
      expect(saver.calls, 0);
    },
  );
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
