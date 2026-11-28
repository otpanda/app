import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_root_io.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/native/native_navigation.dart';

// Synthetic transport and platform replies. This proves actual root/session,
// button and channel routing, not Android provider or biometric behavior.
class _Keys implements NativeKeystore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async =>
      Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
  @override
  Future<bool> hasPendingKey() async => false;
}

class _Store implements NativeSecureStore {
  @override
  Future<String?> readDeviceId() async => 'DEV';
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Browser implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _Google implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

void main() {
  const enabled = bool.fromEnvironment('TOTP_IMPORT_ENABLED');
  setUpAll(() async {
    final loader = FontLoader('Figtree')
      ..addFont(
        File('assets/fonts/Figtree-400.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    await loader.load();
    final titleFont = FontLoader('BricolageGrotesque')
      ..addFont(
        File('assets/fonts/BricolageGrotesque-700.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      )
      ..addFont(
        File('assets/fonts/BricolageGrotesque-800.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    await titleFont.load();
    var flutterRoot = File(Platform.resolvedExecutable).parent;
    while (!File(
      '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).existsSync()) {
      if (flutterRoot.parent.path == flutterRoot.path) {
        throw StateError('Flutter icon font not found');
      }
      flutterRoot = flutterRoot.parent;
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await icons.load();
  });

  testWidgets('exact current native root enabled import synthetic path', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? journal;
    var begins = 0, finishes = 0;
    for (final name in [
      'app.otpanda/google',
      'app.otpanda/native',
      'app.otpanda/app-lock',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(name), (c) async => false);
    }
    m.setMockMethodCallHandler(const MethodChannel('app.otpanda/passkey'), (
      c,
    ) async {
      if (c.method == 'available') return true;
      return '{"id":"cid","rawId":"cid","type":"public-key","response":{"clientDataJSON":"cd","authenticatorData":"ad","signature":"sg","userHandle":null}}';
    });
    m.setMockMethodCallHandler(
      const MethodChannel('app.otpanda/import-journal'),
      (c) async {
        if (c.method == 'read') return journal;
        final a = c.arguments as Map;
        if (c.method == 'claim') {
          if (journal != null) return false;
          journal = a['record'];
          return true;
        }
        if (c.method == 'replace') {
          if (journal != a['expected']) return false;
          journal = a['record'];
          return true;
        }
        if (c.method == 'clear') {
          journal = null;
          return true;
        }
        return null;
      },
    );
    m.setMockMethodCallHandler(
      const MethodChannel('app.otpanda/import-file'),
      (c) async => c.method == 'pickImportFile'
          ? 'otpauth://totp/Synthetic:a?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Synthetic'
          : null,
    );
    final now = DateTime.now();
    final controller = NativeSessionController(
      NativeAuth(
        post: (p, b) async {
          return p.endsWith('challenge')
              ? (
                  status: 200,
                  body: <String, dynamic>{
                    'device_id': 'DEV',
                    'nonce': 'n',
                    'expires_at': 5,
                  },
                )
              : (
                  status: 200,
                  body: <String, dynamic>{
                    'access': 'x' * 43,
                    'access_expires_at': now.millisecondsSinceEpoch + 300000,
                  },
                );
        },
        keystore: _Keys(),
        browser: _Browser(),
        google: _Google(),
        store: _Store(),
        apiOrigin: 'https://example.invalid',
        launchUrl: (c, s) => Uri.parse('https://example.invalid'),
      ),
      clock: () => now,
    );
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: buildAndroidNativeRootForTest(
          session: controller,
          request: (method, path, {body, query, required bearer}) async {
            if (path.endsWith('batch-begin')) {
              begins++;
              return SessionResponse(
                200,
                '{"protocol":2,"admissionId":"${'B' * 32}","token":"otpda_${'A' * 55}","expiresAt":${DateTime.now().millisecondsSinceEpoch + 60000},"options":{"challenge":"${'A' * 43}","rpId":"otpanda.github.io","userVerification":"required","timeout":60000,"allowCredentials":[{"id":"Y2lk","type":"public-key"}]}}',
              );
            }
            if (path.endsWith('batch-finish')) {
              finishes++;
              return const SessionResponse(201, '{"entryIds":["one"]}');
            }
            if (path.endsWith('/session')) {
              return SessionResponse(
                200,
                '{"ownerId":"owner","expiresAt":${DateTime.now().millisecondsSinceEpoch + 300000}}',
              );
            }
            if (path.endsWith('/entries')) {
              return const SessionResponse(200, '{"entries":[]}');
            }
            return const SessionResponse(200, '{}');
          },
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final nav = t.widget<NativeNavigation>(find.byType(NativeNavigation));
    nav.history!.navigate('settings/transfer-codes');
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Import from file'), findsOneWidget);
    await t.tap(find.text('Import from file'));
    await t.pumpAndSettle();
    expect(find.text('Import 1 account'), findsOneWidget);
    await capture(t, key, 'review');
    await t.tap(find.text('Import 1 account'));
    await t.pumpAndSettle();
    expect(find.text('Import saved.'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.textContaining('Nothing is saved until'), findsNothing);
    expect(begins, 1);
    expect(finishes, 1);
    expect(journal, contains('saved'));
    await capture(t, key, 'saved');
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump();
    controller.dispose();
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  }, skip: !enabled);
}

Future<void> capture(WidgetTester t, GlobalKey k, String name) async {
  await t.runAsync(() async {
    final image =
        await (k.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final b = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/test-evidence')..createSync(recursive: true);
    await File('${dir.path}/import-current-root-$name.png')
        .writeAsBytes(b!.buffer.asUint8List());
    image.dispose();
  });
}
