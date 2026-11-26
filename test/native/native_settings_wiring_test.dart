import 'dart:typed_data';
import 'dart:convert';
import 'dart:io' show Platform, File;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/browser_account_page.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/lost_access_page.dart';
import 'package:otpanda_client/native/native_app.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';

class _Ks implements NativeKeystore {
  @override
  Future<Uint8List> ensureKey() async =>
      Uint8List.fromList([4, ...List.filled(64, 1)]);
  @override
  Future<Uint8List> beginNewKey() => ensureKey();
  @override
  Future<void> commitNewKey() async {}
  @override
  Future<void> discardNewKey() async {}
  @override
  Future<bool> hasPendingKey() async => false;
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async =>
      Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
  @override
  Future<void> deleteKey() async {}
}

class _St implements NativeSecureStore {
  String? id = 'DEV';
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class _Br implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _G implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

class _Pk implements PasskeyAssertionSource, PasskeyCreationSource {
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async => null;
  @override
  Future<String?> create(String requestJson) async => null;
}

Future<void> _fonts() async {
  Future<void> load(String family, List<String> paths) async {
    final l = FontLoader(family);
    for (final p in paths) {
      l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
    }
    await l.load();
  }

  await load('Figtree', [
    'assets/fonts/Figtree-400.ttf',
    'assets/fonts/Figtree-500.ttf',
    'assets/fonts/Figtree-600.ttf',
    'assets/fonts/Figtree-700.ttf',
  ]);
  await load('BricolageGrotesque', [
    'assets/fonts/BricolageGrotesque-700.ttf',
    'assets/fonts/BricolageGrotesque-800.ttf',
  ]);
  await load('GoogleSans', ['assets/fonts/GoogleSans.ttf']);
  await load('MaterialIcons', [
    '${Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  late List<(String, String, String?)> calls;
  late bool signedOut;
  Map<String, dynamic>? answers;

  NativeSessionController ctl() => NativeSessionController(
    NativeAuth(
      post: (p, b) async {
        if (p == '/auth/native/renew') {
          return (
            status: 200,
            body: {'access': 'ACC', 'access_expires_at': 9999999999999},
          );
        }
        if (p == '/auth/native/challenge') {
          return (
            status: 200,
            body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
          );
        }
        return (status: 404, body: null);
      },
      keystore: _Ks(),
      browser: _Br(),
      google: _G(),
      store: signedOut ? (_St()..id = null) : _St(),
      apiOrigin: 'https://api.example',
      launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
    ),
  );

  NativeSessionBridge make(NativeSessionController c, {required bool on}) =>
      NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async {
          calls.add((m, p, body));
          if (bearer != 'ACC') return const SessionResponse(401, '{}');
          return SessionResponse(200, jsonEncode(answers?[p] ?? {'x': 1}));
        },
        passkeys: _Pk(),
        creation: _Pk(),
        settingsEnabled: on,
      );

  setUp(() {
    calls = [];
    signedOut = false;
    answers = null;
  });

  testWidgets(
    'real native bridge loads security and passkey list only on their pages',
    (t) async {
      if (Platform.isLinux) await _fonts();
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final now = DateTime.now().millisecondsSinceEpoch;
      answers = {
        '/v1/manage/session': {'ownerId': 'owner', 'expiresAt': now + 60000},
        '/v1/manage/account': {
          'email': 'fixture@example.test',
          'passkeys': 1,
          'google': true,
          'recoveryDevices': 0,
        },
        '/v1/manage/security/status': {
          'enabled': true,
          'pending': [],
          'changes': [],
        },
        '/v1/manage/recovery/status': {
          'emailEscape': {'enabled': false, 'delayDays': 7},
          'passkeys': [
            {
              'id': 'fixture-key',
              'createdAt': 1800000000000,
              'label': 'Fixture phone',
            },
          ],
          'sessions': [],
          'emailRecoveryRequest': null,
        },
      };
      final c = ctl();
      await c.start();
      final b = make(c, on: true);
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: otpandaTheme(),
          home: BrowserAccountPage(
            bridge: b,
            accountOnly: true,
            workspaceEnabled: true,
            navigation: 'settings',
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(calls.where((r) => r.$2 == '/v1/manage/account'), isEmpty);
      expect(calls.where((r) => r.$2.endsWith('/status')), isEmpty);
      await t.tap(find.text('Account & security'));
      await t.pumpAndSettle();
      expect(
        calls.where((r) => r.$2 == '/v1/manage/security/status').length,
        1,
      );
      expect(find.text('Verification settings could not load.'), findsNothing);
      expect(
        t.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isTrue,
      );
      final beforePasskeys = calls
          .where((r) => r.$2 == '/v1/manage/recovery/status')
          .length;
      if (Platform.isLinux)
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/native-settings-enabled.png'),
        );
      await t.tap(find.text('Passkeys'));
      await t.pumpAndSettle();
      expect(
        calls.where((r) => r.$2 == '/v1/manage/recovery/status').length,
        beforePasskeys + 1,
      );
      expect(find.text('Fixture phone'), findsOneWidget);
      if (Platform.isLinux)
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/native-passkeys-enabled.png'),
        );
      expect(find.text('Passkeys could not load here.'), findsNothing);
      expect(calls.every((r) => r.$1 == 'GET'), isTrue);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pumpAndSettle();
      c.dispose();
    },
  );

  test('default off: nothing is available and nothing is called', () async {
    final c = ctl();
    await c.start();
    final b = make(c, on: false);
    expect(b.recoveryAvailable, isFalse);
    expect(b.googleConnectAvailable, isFalse);
    expect(await b.connectGoogle(), 'unavailable');
    expect(b.enrolledClientApprovalAvailable, isFalse);
    await expectLater(b.security('status'), throwsUnsupportedError);
    await expectLater(b.renamePasskey('c', 'n'), throwsUnsupportedError);
    await expectLater(b.emailRecoveryStart('a@b.co'), throwsUnsupportedError);
    expect(calls, isEmpty);
  });

  test('enabled: security status goes through the Bearer bridge', () async {
    final c = ctl();
    await c.start();
    final b = make(c, on: true);
    expect(b.recoveryAvailable, isTrue);
    expect(b.googleConnectAvailable, isTrue);
    expect(await b.security('status'), '{"x":1}');
    expect(calls.single.$1, 'GET');
    expect(calls.single.$2, '/v1/manage/security/status');
    expect(calls.single.$3, isNull);
  });

  test(
    'enabled: approve and approve-change are unavailable, deny is sent',
    () async {
      final c = ctl();
      await c.start();
      final b = make(c, on: true);
      expect(b.enrolledClientApprovalAvailable, isFalse);
      for (final a in ['approve', 'approve-change']) {
        await expectLater(b.security(a, false, 'p1'), throwsUnsupportedError);
      }
      expect(calls, isEmpty);
      await b.security('deny', false, 'p1');
      expect(calls.single.$2, '/v1/manage/security/deny');
      expect(calls.single.$3, '{"pendingId":"p1"}');
    },
  );

  for (final on in [false, true]) {
    testWidgets('signed out, settings ${on ? 'on' : 'off'}: lost-access link', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      signedOut = true;
      final c = ctl();
      final b = make(c, on: on);
      await t.pumpWidget(
        NativeApp(controller: c, googleAvailable: false, authBridge: b),
      );
      await t.pumpAndSettle();
      expect(
        find.text('Lost access to everything?'),
        on ? findsOneWidget : findsNothing,
      );
      if (on) {
        await t.tap(find.text('Lost access to everything?'));
        await t.pumpAndSettle();
        expect(find.byType(LostAccessPage), findsOneWidget);
      }
    });
  }
}
