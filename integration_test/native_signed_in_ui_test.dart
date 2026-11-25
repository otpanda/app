// UNRUN on a device by its author. Needs an Android emulator/device and the
// API repo harness (tool/native-roundtrip-harness.mjs) via `adb reverse`.
// Run with tool/android-signed-in-ui.sh.
//
// Signed-in UI acceptance for the SHARED page. Real AndroidKeystore and the
// app's own NativeAuth sign in to the real auth-only Worker on real D1
// (Miniflare), synthetic account only. Then the actual NativeSessionBridge and
// the actual BrowserAccountPage (the page native_root_io mounts) read Codes
// and Entries, copy a code to the real clipboard, and rename an entry through
// the Edit dialog. D1 is read back directly. Screenshots are PNGs of the
// rendered page, printed as SHOTPART lines and extracted by
// tool/extract-shots.py. Doubles: the Custom Tab (harness mints the code) and
// the in-memory device-id store, as in native_roundtrip_test.dart.
// NOT covered: passkeys, Google, recovery, security, assignment, step-up.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_session.dart';

const _harness = String.fromEnvironment(
  'HARNESS',
  defaultValue: 'http://127.0.0.1:8787',
);
const _prodApi = 'https://otpanda-api.abrahammurciano.workers.dev';

class _MemStore implements NativeSecureStore {
  String? id;
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class _NoGoogle implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

Future<Map<String, dynamic>> _h(
  String method,
  String path, [
  Object? body,
]) async {
  final c = HttpClient();
  try {
    final r = await c.openUrl(method, Uri.parse('$_harness$path'));
    if (body != null) {
      r.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      r.add(utf8.encode(jsonEncode(body)));
    }
    final res = await r.close();
    final t = await res.transform(utf8.decoder).join();
    return {
      'status': res.statusCode,
      ...(jsonDecode(t) as Map<String, dynamic>),
    };
  } finally {
    c.close(force: true);
  }
}

class _HarnessBrowser implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri url) async {
    final p = Uri.splitQueryString(url.fragment);
    final m = await _h('POST', '/__harness/mint', {'challenge': p['c']});
    expect(m['status'], 200, reason: 'harness refused to mint');
    return Uri.parse(
      '$_prodApi/app-return#code=${Uri.encodeQueryComponent(m['code'] as String)}&state=${Uri.encodeQueryComponent(p['s']!)}',
    );
  }
}

final _shotKey = GlobalKey();

Future<void> _shot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 300));
  final b =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: 1);
    final d = await img.toByteData(format: ui.ImageByteFormat.png);
    return d!.buffer.asUint8List();
  });
  expect(bytes!.length, greaterThan(2000), reason: 'blank screenshot $name');
  final s = base64Encode(bytes);
  const n = 800;
  final parts = (s.length / n).ceil();
  for (var i = 0; i < parts; i++) {
    // ignore: avoid_print
    print(
      'SHOTPART:$name:$i:$parts:${s.substring(i * n, (i + 1) * n > s.length ? s.length : (i + 1) * n)}',
    );
  }
}

Future<void> _until(WidgetTester t, Finder f, {int secs = 20}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  await _shot(t, 'failure');
  // Synthetic fixture only: include visible text to diagnose the failed stage.
  // ignore: avoid_print
  print(
    'VISIBLE: ${t.widgetList<Text>(find.byType(Text)).map((v) => v.data ?? '').join(' | ')}',
  );
  fail('never showed: $f');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'signed-in shared page: Codes, Entries, copy, rename on a real Worker/D1',
    (t) async {
      expect((await _h('GET', '/__harness/health'))['ok'], isTrue);
      final seed = await _h('POST', '/__harness/seed');
      expect(seed['status'], 200);
      final entryId = seed['entryId'] as String;

      final ks = AndroidKeystoreAdapter();
      await ks.deleteKey();
      final controller = NativeSessionController(
        NativeAuth(
          post: androidJsonPost(_harness),
          keystore: ks,
          browser: _HarnessBrowser(),
          google: _NoGoogle(),
          store: _MemStore(),
          apiOrigin: _prodApi,
          launchUrl: (c, s) => Uri.parse(
            'https://harness.invalid/#c=${Uri.encodeQueryComponent(c)}&s=${Uri.encodeQueryComponent(s)}',
          ),
        ),
      );
      await t.runAsync(() => controller.auth.signInWithBrowser());
      // The controller holds the session the page's bridge reads from.
      await t.runAsync(() => controller.start());
      expect(controller.phase, NativeSessionPhase.signedIn);

      // The same bridge construction native_root_io uses, minus passkeys and
      // realtime (not part of this acceptance).
      final bridge = NativeSessionBridge(
        controller,
        androidBearerRequest(_harness),
        onLogout: () => controller.signOut(),
      );

      String route = 'codes';
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: _shotKey,
            child: StatefulBuilder(
              builder: (context, set) => BrowserAccountPage(
                bridge: bridge,
                navigation: route,
                onNavigate: (r) => set(() => route = r),
                accountOnly: true,
                workspaceEnabled: true,
                entryEditEnabled: true,
              ),
            ),
          ),
        ),
      );

      // Codes: the seeded entry and its live code, read with the bearer.
      await _until(t, find.text('Fictional service'));
      await _until(t, find.text('123 456'));
      await _shot(t, 'codes');

      // Copy: the real clipboard holds the code.
      await Clipboard.setData(const ClipboardData(text: ''));
      await t.tap(find.byTooltip('Copy code').first);
      await t.pump(const Duration(milliseconds: 500));
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, '123456');
      await _shot(t, 'copied');

      // Entries tab and the Edit dialog.
      await t.tap(find.text('Entries').last);
      await _until(t, find.byKey(Key('edit-$entryId')));
      await _shot(t, 'entries');
      await t.tap(find.byKey(Key('edit-$entryId')));
      await _until(t, find.byKey(const Key('entry-name')));
      await t.enterText(find.byKey(const Key('entry-name')), 'Renamed in UI');
      await _shot(t, 'edit-dialog');
      await t.tap(find.byKey(const Key('entry-save')));
      await _until(t, find.text('Renamed in UI'));
      await _shot(t, 'renamed');

      // The server stored it. The page did not just echo local state.
      expect(
        (await _h('GET', '/__harness/entry?id=$entryId'))['label'],
        'Renamed in UI',
      );

      // A cold page reconstructs the read model, without the optimistic edit overlay.
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await t.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: _shotKey,
            child: BrowserAccountPage(
              bridge: bridge,
              navigation: 'codes',
              accountOnly: true,
              workspaceEnabled: true,
              entryEditEnabled: true,
            ),
          ),
        ),
      );
      await _until(t, find.text('Renamed in UI'));
      await _shot(t, 'renamed-cold-page');
      await t.pumpWidget(const SizedBox());
      await ks.deleteKey();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
