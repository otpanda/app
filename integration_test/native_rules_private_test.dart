// Installed private rule qualification against real Worker/D1 with synthetic
// account data. Real AndroidKeystore sign-in and NativeSessionBridge drive
// Assign v3 and Resume v5, with direct D1 checks before and after confirmation.
// Run with tool/android-rules-private.sh. The browser auth leg is synthetic.
// Does not qualify shared rule OS proof, real providers, or physical devices.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/native/native_assignment.dart';
import 'package:otpanda_client/native/native_rule.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/rule_action_dialog.dart';
import 'package:otpanda_client/assignment_dialog.dart';

const _harness = String.fromEnvironment(
  'HARNESS',
  defaultValue: 'http://127.0.0.1:8787',
);
const _shared = bool.fromEnvironment('SHARED_RULES');
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
final _captureKey = GlobalKey();

Future<void> _shot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 300));
  final b =
      _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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
  try {
    if (_shotKey.currentContext != null) await _shot(t, 'failure');
  } catch (_) {
    /* Diagnostics must never hide the original test failure. */
  }
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
    'installed native private Assign v3 and Resume v5 through actual bridge and D1',
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

      final proof = ChannelDeviceProofSource();
      String? enrolledKeyId;
      if (_shared) {
        expect(await proof.availability(), DeviceProofAvailability.available);
        final spki = await proof.createKeyForEnrollment();
        final begin = await _h('POST', '/__harness/enroll-begin', {
          'jwk': spkiToJwk(spki),
        });
        final c = Map<String, dynamic>.from(begin['challenge'] as Map);
        final fields = DeviceProofFields(
          purpose: c['purpose'],
          ownerId: c['ownerId'],
          keyId: c['keyId'],
          generation: c['generation'],
          challenge: c['challenge'],
          actionDigest: c['actionDigest'],
          expiresAt: c['expiresAt'],
        );
        debugPrint('OS_RULE_PROMPT enrollment');
        final sig = await t.runAsync(() => proof.sign(fields));
        final end = await _h('POST', '/__harness/enroll-finish', {
          'token': begin['token'],
          'signature': base64Url.encode(sig!).replaceAll('=', ''),
        });
        enrolledKeyId = end['keyId'] as String;
        await proof.saveConfirmed(seed['ownerId'] as String, enrolledKeyId);
        await _h('POST', '/__harness/shared');
      }
      Future<({String deviceId, String? keyId, String ownerId})>
      identity() async => (
        ownerId: seed['ownerId'] as String,
        deviceId: controller.session!.deviceId,
        keyId: enrolledKeyId,
      );
      bridge.assignment = NativeAssignmentDriver(
        post: bridge.assignmentPost,
        source: proof,
        identity: identity,
      );
      bridge.rules = NativeRuleDriver(
        post: (path, body) async {
          final r = await bridge.rulePost(path, body);
          debugPrint(
            'SYNTHETIC_RULE_RESPONSE $path ${r.status} localNow=${DateTime.now().millisecondsSinceEpoch} identity=${await identity()} ${jsonEncode(r.body)}',
          );
          return r;
        },
        source: proof,
        identity: identity,
      );
      String route = 'codes';
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        RepaintBoundary(
          key: _captureKey,
          child: MaterialApp(
            theme: otpandaTheme(),
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
        ),
      );

      await _until(t, find.text('123 456'));
      final host = _shotKey.currentContext!;
      final assignment = showDialog<bool>(
        context: host,
        barrierDismissible: false,
        builder: (_) => AssignmentDialog(
          bridge: bridge,
          sourceId: seed['sourceId'] as String,
          eventId: 'seed-code',
          entryId: entryId,
        ),
      );
      await _until(
        t,
        find.text(_shared ? 'Confirm with passkey' : 'Confirm'),
      );
      await _shot(t, 'rule-assign-private');
      expect((await _h('GET', '/__harness/rules'))['rules'], isEmpty);
      debugPrint('OS_RULE_PROMPT step-up');
      await t.tap(find.text(_shared ? 'Confirm with passkey' : 'Confirm'));
      await _until(t, find.text('Assignment confirmed.'));
      await t.tap(find.text('Done'));
      await assignment;
      final rules = (await _h('GET', '/__harness/rules'))['rules'] as List;
      expect(rules.length, 1);
      expect(rules.single['paused_at'], null);
      await _h('POST', '/__harness/rules-pause');
      expect(
        ((await _h('GET', '/__harness/rules'))['rules'] as List)
            .single['paused_at'],
        isNotNull,
      );
      final resume = showDialog<bool>(
        context: host,
        barrierDismissible: false,
        builder: (_) => RuleActionDialog(
          bridge: bridge,
          target: {
            'operation': 'resume',
            'entryId': entryId,
            'ruleId': rules.single['route_id'],
          },
        ),
      );
      await _until(
        t,
        find.text(_shared ? 'Confirm with passkey' : 'Confirm'),
      );
      await _shot(t, 'rule-resume-private');
      expect(
        ((await _h('GET', '/__harness/rules'))['rules'] as List)
            .single['paused_at'],
        isNotNull,
      );
      debugPrint('OS_RULE_PROMPT step-up');
      await t.tap(find.text(_shared ? 'Confirm with passkey' : 'Confirm'));
      await _until(t, find.text('Rule confirmed for future matching codes.'));
      await _shot(t, 'rule-resumed-private');
      await t.tap(find.text('Done'));
      await resume;
      expect(
        ((await _h('GET', '/__harness/rules'))['rules'] as List)
            .single['paused_at'],
        null,
      );
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
