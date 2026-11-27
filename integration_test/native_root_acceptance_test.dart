// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otpanda_client/auth_entry.dart';
import 'package:otpanda_client/native/native_root_io.dart' show buildNativeRoot;
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_session.dart';

const _harness = String.fromEnvironment(
  'HARNESS',
  defaultValue: 'http://127.0.0.1:8787',
);
const _prodApi = 'https://otpanda-api.abrahammurciano.workers.dev';

// The same SharedPreferences-backed store the real root uses, so the real
// root restores the device this test enrolls.
class _ChannelStore implements NativeSecureStore {
  @override
  Future<String?> readDeviceId() async =>
      nativeChannel.invokeMethod<String>('readDeviceId');
  @override
  Future<void> writeDeviceId(String v) =>
      nativeChannel.invokeMethod('writeDeviceId', {'id': v});
  @override
  Future<void> clear() => nativeChannel.invokeMethod('clearDeviceId');
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

Future<void> _until(WidgetTester t, Finder f, {int secs = 25}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return;
  }
  print(
    'VISIBLE: ${t.widgetList<Text>(find.byType(Text)).map((v) => v.data ?? '').join(' | ')}',
  );
  fail('never showed: $f');
}

void _lifecycle(WidgetTester t, List<AppLifecycleState> seq) {
  for (final s in seq) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
}

// Mounts the REAL root (buildNativeRoot, the widget main.dart runs on Android),
// not BrowserAccountPage directly. Needs, at build time:
//   --dart-define=OTPANDA_API_ORIGIN=$HARNESS
// (tool/android-native-root.sh sets both). The test enrolls a synthetic device
// with the real AndroidKeystore and the real native-channel store; the root
// then restores it. Run on a clean emulator only: it deletes the Keystore alias.
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
    print(
      'SHOTPART:$name:$i:$parts:${s.substring(i * n, (i + 1) * n > s.length ? s.length : (i + 1) * n)}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real native root: restore, background/resume, D1-revoked device shows the native sign-in (no Remember, no Temporary demo), cold restart the same',
    (t) async {
      expect(Uri.parse(_harness).host, '127.0.0.1');
      expect(
        const String.fromEnvironment('OTPANDA_API_ORIGIN'),
        _harness,
        reason: 'root must be built with OTPANDA_API_ORIGIN=the harness',
      );
      expect((await _h('GET', '/__harness/health'))['ok'], isTrue);
      await _h('POST', '/__harness/seed');
      final ks = AndroidKeystoreAdapter();
      addTearDown(() async {
        await ks.deleteKey();
        await _ChannelStore().clear();
      });
      await ks.deleteKey();
      final store = _ChannelStore();
      await store.clear();
      final enroll = NativeSessionController(
        NativeAuth(
          post: androidJsonPost(_harness),
          keystore: ks,
          browser: _HarnessBrowser(),
          google: _NoGoogle(),
          store: store,
          apiOrigin: _prodApi,
          launchUrl: (c, s) => Uri.parse(
            'https://harness.invalid/#c=${Uri.encodeQueryComponent(c)}&s=${Uri.encodeQueryComponent(s)}',
          ),
        ),
      );
      await t.runAsync(() => enroll.auth.signInWithBrowser());
      expect(await store.readDeviceId(), isNotNull);

      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        RepaintBoundary(key: _shotKey, child: buildNativeRoot()),
      );
      await _until(t, find.text('123 456'));
      // Exercise actual corrected shell and Details on the installed native root.
      await t.longPress(find.text('Fictional service'));
      await _until(t, find.text('1 selected'));
      await t.tap(find.text('Details'));
      await _until(t, find.byKey(const Key('account-details')));
      expect(find.byKey(const Key('entry-name')), findsNothing);
      await _shot(t, 'root-details-view');
      await t.tap(find.byKey(const Key('entry-edit')));
      await _until(t, find.byKey(const Key('entry-name')));
      expect(find.byKey(const Key('entry-edit-bar')), findsOneWidget);
      await t.enterText(
        find.byKey(const Key('entry-name')),
        'Discarded native edit',
      );
      await _shot(t, 'root-details-edit');
      await t.tap(find.byKey(const Key('entry-cancel')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Discarded native edit'), findsNothing);
      await t.tap(find.byTooltip('Back to codes'));
      await _until(t, find.text('123 456'));

      _lifecycle(t, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      expect(
        (await _h('POST', '/__harness/revoke-device', {
          'deviceId': await store.readDeviceId(),
        }))['revoked'],
        greaterThanOrEqualTo(1),
      );
      await _h('POST', '/__harness/expire-access', {
        'deviceId': await store.readDeviceId(),
      });
      _lifecycle(t, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await _until(t, find.byType(AuthEntry), secs: 60);
      expect(find.text('123 456'), findsNothing);
      expect(find.text('Remember this device'), findsNothing);
      expect(find.text('Temporary demo'), findsNothing);
      expect(await store.readDeviceId(), isNotNull, reason: 'id kept, no wipe');
      print(
        'VISIBLE-REVOKED: ${t.widgetList<Text>(find.byType(Text)).map((v) => v.data ?? '').join(' | ')}',
      );

      await _shot(t, 'root-revoked');

      // Cold restart of the root.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        RepaintBoundary(key: _shotKey, child: buildNativeRoot()),
      );
      await _until(t, find.byType(AuthEntry), secs: 60);
      expect(find.text('123 456'), findsNothing);
      expect(find.text('Remember this device'), findsNothing);
      expect(find.text('Temporary demo'), findsNothing);
      await _shot(t, 'root-cold');
      await t.pumpWidget(const SizedBox());
      await ks.deleteKey();
      await store.clear();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
