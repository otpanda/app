// ignore_for_file: avoid_print
// DEBUG/QUALIFICATION ONLY, UNRUN until an emulator executes it. Disposable emulator only.
// Real buildNativeRoot (the widget main.dart runs on Android) with the real Android channels (Keystore, device-lock BiometricPrompt, workspace-admission,
// seed-custody) against the REAL API runtime on the host (tool/seed-sync-loopback/server.mjs). The current authenticated session comes from the production
// NativeAuth.signInWithPasskey using a synthetic authenticator (NOT the OS credential prompt); the root then renews that device with the real Keystore key.
// The device-lock prompt is the REAL one: tool/android-native-root-gate.sh sets a throwaway PIN and a responder types it. Nothing here weakens production code.
// Proves, in order: no admission before unlock and before the owner is verified; admission after; lock hides at once; offline cold local view after a cold
// remount and unlock; sign-out invalidates the cold selection (a cold remount shows no local view). Each proof prints GATE:<name>.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/auth_entry.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_app_lock.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/native/native_root_io.dart' show buildNativeRoot;
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/native/native_workspace_admission.dart';

const _harness = String.fromEnvironment(
  'HARNESS',
  defaultValue: 'http://127.0.0.1:8787',
);
const _prodApi = 'https://otpanda-api.abrahammurciano.workers.dev';
const _owner = 'fixture-owner';
const _offlineMarker =
    'Offline. Your own saved authenticator codes still work.';

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

class _NoBrowser implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri url) async => null;
}

Future<({int status, String text})> _h(
  String method,
  String path, [
  String? body,
]) async {
  final c = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final r = await c.openUrl(method, Uri.parse('$_harness$path'));
    if (body != null) {
      r.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      r.add(utf8.encode(body));
    }
    final res = await r.close();
    return (status: res.statusCode, text: await utf8.decodeStream(res));
  } finally {
    c.close(force: true);
  }
}

/// Synthetic authenticator over the loopback host. Same interface production sign-in consumes.
class _LoopbackPasskey implements PasskeyAssertionSource {
  const _LoopbackPasskey();
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async {
    final r = await _h('POST', '/__loopback/assert', requestJson);
    return r.status == 200 ? r.text : null;
  }
}

Future<int> _sessionReads() async =>
    (jsonDecode((await _h('GET', '/__loopback/counters')).text)
            as Map)['sessionReads']
        as int;

Future<void> _pump(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _until(
  WidgetTester t,
  bool Function() ok,
  String what, {
  int secs = 40,
}) async {
  final end = DateTime.now().add(Duration(seconds: secs));
  while (DateTime.now().isBefore(end)) {
    await _pump(t, 300);
    if (ok()) return;
  }
  print(
    'VISIBLE: ${t.widgetList<Text>(find.byType(Text)).map((v) => v.data ?? '').join(' | ')}',
  );
  fail('never reached: $what');
}

Future<NativeWorkspaceScope?> _discover(WidgetTester t) async =>
    (await t.runAsync<NativeWorkspaceScope?>(
      () => NativeWorkspaceAdmission().discover(),
    ));

String _publicRfcCode(int millis) {
  final counter = ByteData(8)..setUint64(0, millis ~/ 30000);
  final digest = Hmac(
    sha1,
    utf8.encode('12345678901234567890'),
  ).convert(counter.buffer.asUint8List()).bytes;
  final off = digest.last & 15;
  final value =
      ((digest[off] & 127) << 24) |
      (digest[off + 1] << 16) |
      (digest[off + 2] << 8) |
      digest[off + 3];
  return (value % 100000000).toString().padLeft(8, '0');
}

bool _showsPublicRfcCode(WidgetTester t) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return t
      .widgetList<Text>(find.byType(Text))
      .any(
        (v) =>
            v.data == _publicRfcCode(now) ||
            v.data == _publicRfcCode(now - 1000),
      );
}

void _gate(String name) => print('GATE:$name');

void _lifecycle(WidgetTester t, List<AppLifecycleState> seq) {
  for (final s in seq) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
}

Future<void> _mountRoot(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(RepaintBoundary(key: _shotKey, child: buildNativeRoot()));
}

Future<void> _unlock(WidgetTester t) async {
  await _until(
    t,
    () => find.text('Device unlock').evaluate().isNotEmpty,
    'device-unlock button',
  );
  await t.tap(find.text('Device unlock'));
  // The responder script types the throwaway PIN into the real device credential prompt.
  await _until(
    t,
    () => find.text('OTPanda is locked').evaluate().isEmpty,
    'unlock via the real device credential prompt',
    secs: 60,
  );
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
    print(
      'SHOTPART:$name:$i:$parts:${s.substring(i * n, (i + 1) * n > s.length ? s.length : (i + 1) * n)}',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'installed real-root gate: admission absent before verified owner and local unlock, present after, lock hides at once, cold local view offline, sign-out invalidates',
    (t) async {
      expect(Uri.parse(_harness).host, '127.0.0.1');
      expect(
        const String.fromEnvironment('OTPANDA_API_ORIGIN'),
        _harness,
        reason: 'root must be built with OTPANDA_API_ORIGIN=the loopback host',
      );
      expect(
        (jsonDecode((await _h('GET', '/__loopback/counters')).text) as Map)
            .containsKey('sessionReads'),
        isTrue,
        reason: 'loopback host lacks the counters route',
      );
      await _h('POST', '/__loopback/outage', '{"on":false}');
      final ks = AndroidKeystoreAdapter();
      final store = _ChannelStore();
      addTearDown(() async {
        await _h('POST', '/__loopback/outage', '{"on":false}');
        await ks.deleteKey();
        await store.clear();
      });
      await ks.deleteKey();
      await store.clear();
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));

      // Qualification-only channel substitute. Root uses AndroidPasskeySource unchanged;
      // only Credential Manager assertion acquisition is synthetic. Device lock is real.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(passkeyChannel, (call) async {
            if (call.method == 'available') return true;
            if (call.method == 'get') {
              return const _LoopbackPasskey().get(
                (call.arguments as Map)['requestJson'] as String,
              );
            }
            throw PlatformException(code: 'unsupported_qualification_method');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(passkeyChannel, null),
      );
      // Precondition: a clean emulator has no admitted workspace.
      expect(await _discover(t), isNull, reason: 'emulator not clean');

      // Current authenticated session: production sign-in, synthetic authenticator.
      final enroll = NativeSessionController(
        NativeAuth(
          post: androidJsonPost(_harness),
          keystore: ks,
          browser: _NoBrowser(),
          google: _NoGoogle(),
          store: store,
          apiOrigin: _prodApi,
          launchUrl: (c, s) => Uri.parse('https://harness.invalid/#c=$c&s=$s'),
          passkeys: _LoopbackPasskey(),
        ),
      );
      await t.runAsync(() => enroll.auth.signInWithPasskey());
      expect(await store.readDeviceId(), isNotNull);
      _gate('session_enrolled');

      // Turn the real device lock on. Uses the production controller and the real prompt.
      final setup = LocalLockController(ChannelLocalLock());
      await t.runAsync(setup.load);
      await t.runAsync(() => setup.change(true));
      expect(setup.enabled, isTrue, reason: setup.error ?? 'lock not enabled');
      setup.dispose();
      _gate('device_lock_enabled');

      // 1. Locked cold start: no owner verification, no admission.
      final readsBefore = await _sessionReads();
      await _mountRoot(t);
      await _until(
        t,
        () => find.text('OTPanda is locked').evaluate().isNotEmpty,
        'locked screen',
      );
      await _pump(t, 8000);
      expect(find.text('OTPanda is locked'), findsOneWidget);
      expect(find.byType(AuthEntry), findsNothing);
      expect(await _discover(t), isNull, reason: 'admitted while locked');
      expect(
        await _sessionReads(),
        readsBefore,
        reason: 'owner verification ran while locked',
      );
      await _shot(t, 'locked_no_owner_read_no_admission');
      _gate('locked_no_owner_read_no_admission');

      // 2. Unlock: owner verified from the real session response, admission enabled.
      await _unlock(t);
      await _until(
        t,
        () =>
            find.byType(AuthEntry).evaluate().isEmpty &&
            find.text('OTPanda is locked').evaluate().isEmpty,
        'signed-in root',
      );
      NativeWorkspaceScope? scope;
      final end = DateTime.now().add(const Duration(seconds: 40));
      while (scope == null && DateTime.now().isBefore(end)) {
        await _pump(t, 500);
        scope = await _discover(t);
      }
      expect(scope, isNotNull, reason: 'workspace never admitted after unlock');
      expect(scope!.owner, _owner);
      expect(await _sessionReads(), greaterThan(readsBefore));
      await _shot(t, 'admitted_after_owner_and_unlock');
      _gate('admitted_after_owner_and_unlock');
      // Let the authenticated snapshot publish before the lock and offline checks.
      await _pump(t, 6000);

      // Explicit user-gesture enrollment through the actual root's settings.
      // This runs production composition, not a separately assembled coordinator.
      await t.tap(find.byTooltip('Account & security'));
      await _pump(t, 1000);
      final accountSettings = find.byKey(
        const Key('settings-settings/account-security'),
      );
      await _until(
        t,
        () => accountSettings.evaluate().isNotEmpty,
        'account settings category',
      );
      await t.tap(accountSettings);
      await _until(
        t,
        () => find.text('Set up on this device').evaluate().isNotEmpty,
        'offline setup setting',
      );
      await t.ensureVisible(find.text('Set up on this device'));
      await t.tap(find.text('Set up on this device'));
      await _until(
        t,
        () => find.text('Check offline setup').evaluate().isNotEmpty,
        'root-driven enrollment',
        secs: 90,
      );
      _gate('root_enrollment_confirmed');
      // Wait for the root's pull listener and prove it by a real local code after outage.
      await _pump(t, 6000);
      // 3. Lock hides immediately.
      _lifecycle(t, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await t.pump();
      expect(find.text('OTPanda is locked'), findsOneWidget);
      expect(find.text(_offlineMarker), findsNothing);
      _gate('lock_hides_immediately');
      _lifecycle(t, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);

      // 4. Cold remount with the server down: the cold local view survives, after unlock only.
      await _h('POST', '/__loopback/outage', '{"on":true}');
      await _mountRoot(t);
      await _until(
        t,
        () => find.text('OTPanda is locked').evaluate().isNotEmpty,
        'locked after cold remount',
      );
      expect(find.text(_offlineMarker), findsNothing);
      await _unlock(t);
      await _until(
        t,
        () => find.text(_offlineMarker).evaluate().isNotEmpty,
        'cold local view while offline',
        secs: 90,
      );
      expect(
        find.text(
          'Local codes could not be opened. Your saved data has not been reset.',
        ),
        findsNothing,
      );
      expect((await _discover(t))?.owner, _owner);
      print(
        'VISIBLE-OFFLINE: ${t.widgetList<Text>(find.byType(Text)).map((v) => v.data ?? '').join(' | ')}',
      );
      await _until(
        t,
        () =>
            find.text('Local code unavailable').evaluate().isEmpty &&
            _showsPublicRfcCode(t),
        'root-downloaded offline TOTP',
        secs: 60,
      );
      _gate('root_downloaded_offline_totp');
      await _shot(t, 'cold_local_view_offline_after_unlock');
      _gate('cold_local_view_offline_after_unlock');
      // Actual pause/resume with the server still unavailable, not a remount.
      _lifecycle(t, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await t.pump();
      expect(find.text(_offlineMarker), findsNothing);
      _lifecycle(t, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await _unlock(t);
      await _until(
        t,
        () => find.text(_offlineMarker).evaluate().isNotEmpty,
        'paused offline cold reopening',
        secs: 90,
      );
      expect(find.text('Local code unavailable'), findsNothing);
      expect(_showsPublicRfcCode(t), isTrue);
      await _shot(t, 'paused_offline_reopened');
      _gate('paused_offline_reopened');
      // Explicit D2 acceptance: lock-disabled background/resume cannot rely on
      // a privacy-permission transition. Keep server unavailable throughout.
      final disable = LocalLockController(ChannelLocalLock());
      await t.runAsync(disable.load);
      await t.runAsync(() => disable.change(false));
      expect(disable.enabled, isFalse);
      disable.dispose();
      await _mountRoot(t);
      await _until(
        t,
        () => find.text(_offlineMarker).evaluate().isNotEmpty,
        'lock-disabled cold offline root',
        secs: 90,
      );
      expect(_showsPublicRfcCode(t), isTrue);
      _lifecycle(t, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      await t.pump();
      expect(
        find.text(_offlineMarker),
        findsNothing,
        reason: 'local view must close during paused before reopen',
      );
      expect(
        _showsPublicRfcCode(t),
        isFalse,
        reason: 'offline code must not remain mounted while paused',
      );
      _lifecycle(t, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await _until(
        t,
        () =>
            find.text(_offlineMarker).evaluate().isNotEmpty &&
            _showsPublicRfcCode(t),
        'lock-disabled paused offline reopening',
        secs: 90,
      );
      await _shot(t, 'lock_disabled_paused_offline_rfc');
      _gate('lock_disabled_paused_offline_rfc');
      await _h('POST', '/__loopback/outage', '{"on":false}');

      // 5. Sign out invalidates the cold selection.
      await _mountRoot(t);
      await _until(
        t,
        () =>
            find.byType(AuthEntry).evaluate().isEmpty &&
            find.text(_offlineMarker).evaluate().isEmpty,
        'signed-in root before sign-out',
        secs: 60,
      );
      await _pump(t, 4000);
      final out = find.byKey(const Key('browser-sign-out'));
      if (out.evaluate().isEmpty) {
        // Sign out lives in the settings hub; the exact route is a harness detail. Print the screen for the first run.
        print(
          'SETTINGS-ROUTE-NEEDED: ${t.widgetList<Text>(find.byType(Text)).map((v) => v.data ?? '').join(' | ')}',
        );
        final tip = find.byTooltip('Account & security');
        if (tip.evaluate().isNotEmpty) await t.tap(tip.first);
        await _pump(t, 1500);
      }
      await _until(
        t,
        () => find.byKey(const Key('browser-sign-out')).evaluate().isNotEmpty,
        'sign-out button',
        secs: 15,
      );
      await t.ensureVisible(find.byKey(const Key('browser-sign-out')));
      await t.tap(find.byKey(const Key('browser-sign-out')));
      final confirm = find.text('Sign out');
      await _pump(t, 1500);
      if (confirm.evaluate().length > 1) await t.tap(confirm.last);
      final gone = DateTime.now().add(const Duration(seconds: 40));
      while (await _discover(t) != null && DateTime.now().isBefore(gone)) {
        await _pump(t, 500);
      }
      expect(
        await _discover(t),
        isNull,
        reason: 'cold selection survived sign-out',
      );
      _gate('signout_invalidated_cold_selection');
      await _mountRoot(t);
      await _until(
        t,
        () =>
            find.byType(AuthEntry).evaluate().isNotEmpty &&
            find.text('OTPanda is locked').evaluate().isEmpty,
        'cold signed-out root with previously disabled local lock',
      );
      await _pump(t, 6000);
      expect(find.text(_offlineMarker), findsNothing);
      expect(await _discover(t), isNull);
      await _shot(t, 'cold_root_after_signout_no_local_view');
      _gate('cold_root_after_signout_no_local_view');

      // Leave the emulator without a lock flag.
      final cleanup = LocalLockController(ChannelLocalLock());
      await t.runAsync(cleanup.load);
      await t.runAsync(() => cleanup.change(false));
      cleanup.dispose();
      await t.pumpWidget(const SizedBox());
      _gate('complete');
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
