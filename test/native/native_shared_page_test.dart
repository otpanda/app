import 'dart:convert';
import 'dart:io' show Platform, File;

import 'package:flutter/services.dart';

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/native/native_app.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
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

void main() {
  testWidgets(
    'shared account page renders fictional Codes through the native bridge',
    (t) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final calls = <String>[];
      final c = NativeSessionController(
        NativeAuth(
          post: (p, b) async {
            if (p == '/auth/native/logout') {
              calls.add('POST /auth/native/logout');
              return (status: 204, body: null);
            }
            if (p == '/auth/native/challenge') {
              return (
                status: 200,
                body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
              );
            }
            if (p == '/auth/native/renew') {
              return (
                status: 200,
                body: {'access': 'tok', 'access_expires_at': now + 300000},
              );
            }
            return (status: 404, body: null);
          },
          keystore: _Ks(),
          browser: _Br(),
          google: _G(),
          store: _St(),
          apiOrigin: 'https://api.example',
          launchUrl: (c, s) => Uri.parse('https://x/'),
        ),
      );
      final bridge = NativeSessionBridge(c, (
        m,
        path, {
        body,
        query,
        required bearer,
      }) async {
        calls.add('$m $path');
        expect(bearer, 'tok');
        return SessionResponse(
          200,
          jsonEncode(switch (path) {
            '/v1/manage/session' => {
              'ownerId': 'synthetic',
              'expiresAt': now + 300000,
            },
            '/v1/manage/entries' => {
              'entries': [
                {
                  'entry_id': 'e1',
                  'service_name': 'Example Mail',
                  'capabilities': {'manage': true},
                },
                {
                  'entry_id': 'e2',
                  'service_name': 'Sample Bank',
                  'capabilities': {'manage': true},
                },
              ],
            },
            '/v1/manage/active-codes' => {
              'records': [
                {
                  'entryId': 'e1',
                  'code': '112233',
                  'receivedAt': now - 1000,
                  'expiresAt': now + 29000,
                },
                {
                  'entryId': 'e2',
                  'code': '445566',
                  'receivedAt': now - 2000,
                  'expiresAt': now + 28000,
                },
              ],
            },
            '/v1/manage/sources' => {'sources': []},
            '/v1/manage/unassigned' => {'records': []},
            _ => {'records': []},
          }),
        );
      }, onLogout: () => c.signOut());
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        for (final pair in [
          ('Figtree', 'assets/fonts/Figtree-400.ttf'),
          ('BricolageGrotesque', 'assets/fonts/BricolageGrotesque-700.ttf'),
          ('CodeMono', 'assets/fonts/CodeMono-Regular.ttf'),
          (
            'MaterialIcons',
            '${Platform.environment['FLUTTER_ROOT'] ?? '/downloads/otpanda/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ]) {
          final loader = FontLoader(pair.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(pair.$2).readAsBytesSync()),
              ),
            );
          await loader.load();
        }
      });
      await t.pumpWidget(
        NativeApp(
          controller: c,
          googleAvailable: false,
          authBridge: bridge,
          signedInBuilder: (context) => BrowserAccountPage(
            bridge: bridge,
            accountOnly: true,
            signOutEnabled: true,
            workspaceEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Your codes'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Example Mail'), findsWidgets);
      expect(find.textContaining('112233'), findsWidgets);
      expect(calls, contains('GET /v1/manage/active-codes'));
      expect(calls.every((s) => s.startsWith('GET ')), isTrue);
      expect(find.byTooltip('Add authenticator'), findsNothing);
      // Pixel baseline is the Linux CI render; font rasterization differs on
      // Windows and macOS. Every functional assertion above runs on all OSes.
      if (Platform.isLinux) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/native_codes_390.png'),
        );
      }
      await t.tap(find.byTooltip('Account & security').first);
      await t.pumpAndSettle();
      final signOut = find.byKey(const Key('browser-sign-out'));
      await t.ensureVisible(signOut);
      expect(signOut, findsOneWidget);
      await t.tap(signOut);
      await t.pumpAndSettle();
      expect(calls, contains('POST /auth/native/logout'));
      expect(c.phase, NativeSessionPhase.signedOut);
      expect(find.text('Welcome to OTPanda.'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
