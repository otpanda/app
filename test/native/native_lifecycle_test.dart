import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
  int deletes = 0;
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
  Future<void> deleteKey() async => deletes++;
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

class _Rig {
  _Rig({this.ttlMs = 300000});
  final int ttlMs;
  int now = 1800000000000;
  int renews = 0, challenges = 0;
  int renewStatus = 200; // 200, 401 (revoked or blocked), 503 (outage)
  bool throwOnRenew = false;
  Completer<void>? renewGate;
  final ks = _Ks();
  final store = _St();
  final bearers = <String>[];
  late final NativeSessionController c = NativeSessionController(
    NativeAuth(
      post: (p, b) async {
        if (p == '/auth/native/challenge') {
          challenges++;
          return (
            status: 200,
            body: {
              'device_id': 'DEV',
              'nonce': 'n$challenges',
              'expires_at': 5,
            },
          );
        }
        if (p == '/auth/native/renew') {
          renews++;
          if (renewGate != null) await renewGate!.future;
          if (throwOnRenew) throw const SocketException('down');
          if (renewStatus != 200) return (status: renewStatus, body: null);
          return (
            status: 200,
            body: {'access': 'tok$renews', 'access_expires_at': now + ttlMs},
          );
        }
        return (status: 404, body: null);
      },
      keystore: ks,
      browser: _Br(),
      google: _G(),
      store: store,
      apiOrigin: 'https://api.example',
      launchUrl: (c, s) => Uri.parse('https://x/'),
    ),
    clock: () => DateTime.fromMillisecondsSinceEpoch(now),
  );
  late final NativeSessionBridge bridge = NativeSessionBridge(c, (
    m,
    path, {
    body,
    query,
    required bearer,
  }) async {
    bearers.add(bearer);
    return SessionResponse(
      200,
      jsonEncode(switch (path) {
        '/v1/manage/session' => {
          'ownerId': 'synthetic',
          'expiresAt': now + ttlMs,
        },
        '/v1/manage/entries' => {
          'entries': [
            {
              'entry_id': 'e1',
              'service_name': 'Example Mail',
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
          ],
        },
        _ => {'records': [], 'sources': []},
      }),
    );
  });
  Future<void> mount(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      NativeApp(
        controller: c,
        googleAvailable: false,
        signedInBuilder: (context) => BrowserAccountPage(
          bridge: bridge,
          accountOnly: true,
          workspaceEnabled: true,
          clock: () => now,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> adv(WidgetTester t, int ms) async {
    now += ms;
    await t.pump(Duration(milliseconds: ms));
    await t.pump(const Duration(milliseconds: 50));
  }
}

void _bg(WidgetTester t) {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
}

void _fg(WidgetTester t) {
  for (final s in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  testWidgets(
    'silent renew near expiry: one renew, no sign-in screen, no wipe, newer bearer used',
    (t) async {
      final r = _Rig(ttlMs: 90000);
      await r.mount(t);
      expect(find.textContaining('Example Mail'), findsWidgets);
      final first = r.renews;
      expect(first, greaterThanOrEqualTo(1));
      await r.adv(t, 40000); // inside the 60 s margin
      await r.adv(t, 2000);
      expect(
        r.renews,
        first + 1,
        reason: 'exactly one silent renew for the expiring token',
      );
      expect(find.textContaining('Example Mail'), findsWidgets);
      expect(find.text('Sign in'), findsNothing);
      expect(r.ks.deletes, 0);
      expect(r.store.id, 'DEV');
      expect(await r.c.accessToken(), 'tok${r.renews}');
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background then resume after the token expired: one renew, signed in, no wipe',
    (t) async {
      final r = _Rig(ttlMs: 120000);
      await r.mount(t);
      final before = r.renews;
      _bg(t);
      r.now += 600000; // ten minutes in the background, access long expired
      _fg(t);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(seconds: 2));
      expect(r.renews - before, 1, reason: 'resume renews once, never a storm');
      expect(r.c.phase, NativeSessionPhase.signedIn);
      expect(find.textContaining('Example Mail'), findsWidgets);
      expect(r.ks.deletes, 0);
      // rapid repeated resumes while a renew is not needed stay quiet
      for (var i = 0; i < 5; i++) {
        _bg(t);
        _fg(t);
      }
      await t.pump(const Duration(seconds: 2));
      expect(
        r.renews - before,
        1,
        reason: 'fresh token: repeated resumes cause no extra renew',
      );
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'revoked or blocked enrollment: renew 401 on resume fails closed to sign-in, keeps the Keystore key and device id',
    (t) async {
      final r = _Rig(ttlMs: 120000);
      await r.mount(t);
      r.renewStatus = 401;
      _bg(t);
      r.now += 600000;
      _fg(t);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(seconds: 2));
      expect(r.c.phase, NativeSessionPhase.signInRequired);
      expect(
        find.textContaining('Example Mail'),
        findsNothing,
        reason: 'no codes shown for a rejected session',
      );
      expect(
        r.ks.deletes,
        0,
        reason: 'a 401 is not proof of revocation: no key wipe',
      );
      expect(r.store.id, 'DEV');
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'outage on resume keeps the session state (paused) and shows Retry (no sign-in), and Retry recovers',
    (t) async {
      final r = _Rig(ttlMs: 120000);
      await r.mount(t);
      r.renewStatus = 503;
      _bg(t);
      r.now += 600000;
      _fg(t);
      await t.pump(const Duration(seconds: 2));
      expect(r.c.phase, NativeSessionPhase.offline);
      expect(r.ks.deletes, 0);
      expect(r.store.id, 'DEV');
      r.renewStatus = 200;
      await t.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('native-retry')), findsOneWidget);
      expect(find.textContaining('Example Mail'), findsNothing);
      await t.tap(find.byKey(const Key('native-retry')));
      await t.pumpAndSettle();
      expect(r.c.phase, NativeSessionPhase.signedIn);
      expect(find.textContaining('Example Mail'), findsWidgets);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cold restart: a new controller with the stored device id renews and shows codes',
    (t) async {
      final r = _Rig();
      await r.mount(t);
      await t.pumpWidget(const SizedBox.shrink());
      final cold = _Rig()..store.id = 'DEV';
      await cold.c.start();
      expect(cold.c.phase, NativeSessionPhase.signedIn);
      await cold.mount(t);
      expect(find.textContaining('Example Mail'), findsWidgets);
      expect(cold.ks.deletes, 0);
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'expired token, held renew, three resumes plus timer ticks: exactly one renew; success then uses the new bearer',
    (t) async {
      final r = _Rig(ttlMs: 120000);
      await r.mount(t);
      final before = r.renews;
      r.renewGate = Completer<void>();
      _bg(t);
      r.now += 600000;
      for (var i = 0; i < 3; i++) {
        _fg(t);
        _bg(t);
      }
      _fg(t);
      await t.pump(
        const Duration(seconds: 3),
      ); // timer samples in the same window
      expect(
        r.renews - before,
        1,
        reason: 'single flight while the renew is held',
      );
      r.renewGate!.complete();
      r.renewGate = null;
      await t.pump(const Duration(seconds: 2));
      expect(r.renews - before, 1);
      expect(r.c.phase, NativeSessionPhase.signedIn);
      final mark = r.bearers.length;
      await r.bridge.read('/v1/manage/entries');
      expect(
        r.bearers.sublist(mark).every((b) => b == 'tok${r.renews}'),
        isTrue,
        reason: 'the actual API read carries the renewed bearer',
      );
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'held renew that fails (503): still one renew for the same window, state kept',
    (t) async {
      final r = _Rig(ttlMs: 120000);
      await r.mount(t);
      final before = r.renews;
      r.renewGate = Completer<void>();
      r.renewStatus = 503;
      _bg(t);
      r.now += 600000;
      for (var i = 0; i < 3; i++) {
        _fg(t);
        _bg(t);
      }
      _fg(t);
      await t.pump(const Duration(seconds: 3));
      expect(r.renews - before, 1);
      r.renewGate!.complete();
      await t.pump(const Duration(seconds: 2));
      expect(r.c.phase, NativeSessionPhase.offline);
      expect(r.ks.deletes, 0);
      expect(r.store.id, 'DEV');
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'thrown transport error on renew: offline, key and device id retained',
    (t) async {
      final r = _Rig(ttlMs: 120000);
      await r.mount(t);
      r.throwOnRenew = true;
      _bg(t);
      r.now += 600000;
      _fg(t);
      await t.pump(const Duration(seconds: 3));
      expect(r.c.phase, NativeSessionPhase.offline);
      expect(r.ks.deletes, 0);
      expect(r.store.id, 'DEV');
      await t.pumpWidget(const SizedBox.shrink());
    },
  );

  test('revoked then cold restart: bounded renew (at most the built-in single retry), signInRequired, no retry loop, key and id kept', () async {
    final r = _Rig();
    r.store.id = 'DEV';
    r.renewStatus = 401;
    await r.c.start();
    expect(r.c.phase, NativeSessionPhase.signInRequired);
    // The auth layer retries a 401 renew once with a fresh challenge (by design).
    final settled = r.renews;
    expect(settled, lessThanOrEqualTo(2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(r.renews, settled, reason: 'no background renew loop after 401');
    expect(r.ks.deletes, 0);
    expect(r.store.id, 'DEV');
  });
}
