import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart' show Checkbox;
import 'package:flutter/widgets.dart' show Key, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_app.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_session.dart';

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
  String? id;
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class _Br implements BrowserHandoff {
  int runs = 0;
  Uri? last;
  @override
  Future<Uri?> run(Uri u) async {
    runs++;
    last = u;
    return null;
  }
}

class _G implements GoogleIdTokenSource {
  @override
  bool get available => true;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

void main() {
  late _St st;
  late _Br br;
  late int renewStatus;

  NativeSessionController ctl() => NativeSessionController(
    NativeAuth(
      post: (p, b) async {
        if (p == '/auth/native/challenge') {
          return (
            status: 200,
            body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
          );
        }
        if (p == '/auth/native/renew') {
          return renewStatus == 200
              ? (
                  status: 200,
                  body: {'access': 'a', 'access_expires_at': 9999999999999},
                )
              : (status: renewStatus, body: null);
        }
        if (p == '/auth/native/google/begin') {
          return (status: 200, body: {'nonce': 'N', 'expires_at': 9});
        }
        return (status: 404, body: null);
      },
      keystore: _Ks(),
      browser: br,
      google: _G(),
      store: st,
      apiOrigin: 'https://api.example',
      launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
    ),
  );

  setUp(() {
    st = _St();
    br = _Br();
    renewStatus = 200;
  });

  Future<void> pumpApp(
    WidgetTester t,
    NativeSessionController c, {
    bool google = true,
  }) async {
    t.view.physicalSize = const Size(390, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(NativeApp(controller: c, googleAvailable: google));
    await t.pumpAndSettle();
  }

  testWidgets(
    'signed out: Google and browser buttons; browser cancel shows no error',
    (t) async {
      await pumpApp(t, ctl());
      expect(find.text('Sign in to OTPanda'), findsOneWidget);
      expect(find.byKey(const Key('native-google')), findsOneWidget);
      await t.tap(find.byKey(const Key('native-browser')));
      await t.pumpAndSettle();
      expect(br.runs, 1);
      expect(find.byKey(const Key('native-error')), findsNothing);
    },
  );

  testWidgets('google hidden when unavailable (F-Droid shape)', (t) async {
    await pumpApp(t, ctl(), google: false);
    expect(find.byKey(const Key('native-google')), findsNothing);
    expect(find.byKey(const Key('native-browser')), findsOneWidget);
  });

  testWidgets('stored device renews and shows signed in with Sign out', (
    t,
  ) async {
    st.id = 'DEV';
    await pumpApp(t, ctl());
    expect(find.text('You are signed in'), findsOneWidget);
    expect(find.byKey(const Key('native-signout')), findsOneWidget);
  });

  testWidgets('renew 401 shows sign-in-again and keeps state', (t) async {
    st.id = 'DEV';
    renewStatus = 401;
    await pumpApp(t, ctl());
    expect(find.text('Sign in again'), findsOneWidget);
    expect(st.id, 'DEV');
  });

  testWidgets('outage shows retry and keeps state', (t) async {
    st.id = 'DEV';
    renewStatus = 503;
    await pumpApp(t, ctl());
    expect(find.text('Cannot reach OTPanda'), findsOneWidget);
    expect(find.byKey(const Key('native-retry')), findsOneWidget);
    expect(st.id, 'DEV');
  });

  group('shared sign-in screen (same AuthEntry as web)', () {
    Future<void> pumpShared(
      WidgetTester t,
      NativeSessionController c, {
      required bool google,
    }) async {
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final b = NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async =>
            const SessionResponse(401, '{}'),
        googleAvailable: google,
      );
      await t.pumpWidget(
        NativeApp(controller: c, googleAvailable: google, authBridge: b),
      );
      await t.pumpAndSettle();
    }

    testWidgets('shows web labels, no Sign in with browser button', (t) async {
      await pumpShared(t, ctl(), google: true);
      expect(find.text('Welcome to OTPanda.'), findsOneWidget);
      expect(find.text('Sign in with a passkey'), findsOneWidget);
      expect(find.text('Create account with a passkey'), findsOneWidget);
      expect(find.text('Remember this device'), findsOneWidget);
      expect(find.text('Sign in with browser'), findsNothing);
      expect(find.byKey(const Key('native-browser')), findsNothing);
      // Widget-test render, Linux baseline only. Not a device screenshot.
      if (Platform.isLinux) {
        await expectLater(
          find.byType(NativeApp),
          matchesGoldenFile('goldens/native_signin_390.png'),
        );
      }
    });

    testWidgets('Google with SDK uses the OS source, not the browser', (
      t,
    ) async {
      await pumpShared(t, ctl(), google: true);
      await t.tap(find.textContaining('Google').first);
      await t.pumpAndSettle();
      expect(br.runs, 0);
    });

    testWidgets('Google without SDK opens the browser handoff directly', (
      t,
    ) async {
      await pumpShared(t, ctl(), google: false);
      await t.tap(find.byType(Checkbox));
      await t.tap(find.textContaining('Google').first);
      await t.pumpAndSettle();
      expect(br.runs, 1);
      expect(br.last!.fragment, endsWith('&provider=google&remember=0'));
    });
  });

  group('OS passkey sign-in', () {
    final good = {
      'token': 'tok',
      'options': {
        'rpId': 'otpanda.github.io',
        'userVerification': 'required',
        'challenge': 'A' * 43,
      },
      'expires_at': DateTime.now().millisecondsSinceEpoch + 100000,
    };
    String assertion({bool handle = true}) =>
        '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","authenticatorData":"a","signature":"s"${handle ? ',"userHandle":"u"' : ''}}}';
    test('request json is discoverable and UV required', () {
      final j = passkeyLoginRequestJson(
        good,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(j, contains('"allowCredentials":[]'));
      expect(j, contains('"userVerification":"required"'));
    });
    test('wrong rp or expired begin is rejected', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
        () => passkeyLoginRequestJson({
          ...good,
          'options': {...(good['options'] as Map), 'rpId': 'evil.example'},
        }, nowMs: now),
        throwsA(isA<PasskeyException>()),
      );
      expect(
        () => passkeyLoginRequestJson({...good, 'expires_at': 1}, nowMs: now),
        throwsA(isA<PasskeyException>()),
      );
    });

    Future<(NativeSessionController, List<String>)> run(
      String? raw, {
      int complete = 200,
    }) async {
      final paths = <String>[];
      final c = NativeSessionController(
        NativeAuth(
          post: (p, b) async {
            paths.add(p);
            if (p == '/auth/native/passkey/begin') {
              return (status: 200, body: Map<String, dynamic>.from(good));
            }
            if (p == '/auth/native/passkey/complete') {
              return complete == 200
                  ? (
                      status: 200,
                      body: {
                        'device_id': 'DEV',
                        'access': 'a',
                        'access_expires_at': 9999999999999,
                      },
                    )
                  : (status: complete, body: {'error': 'invalid_grant'});
            }
            return (status: 404, body: null);
          },
          keystore: _Ks(),
          browser: br,
          google: _G(),
          store: st,
          apiOrigin: 'https://api.example',
          launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
          passkeys: _Pk(raw),
        ),
      );
      await c.signInWithPasskey();
      return (c, paths);
    }

    test('success signs in and stores the device', () async {
      final (c, paths) = await run(assertion());
      expect(c.phase, NativeSessionPhase.signedIn);
      expect(st.id, 'DEV');
      expect(paths, [
        '/auth/native/passkey/begin',
        '/auth/native/passkey/complete',
      ]);
    });
    test('cancel does not call complete and leaves signed out', () async {
      final (c, paths) = await run(null);
      expect(c.phase, isNot(NativeSessionPhase.signedIn));
      expect(paths, ['/auth/native/passkey/begin']);
    });
    test('missing user handle is not posted', () async {
      final (c, paths) = await run(assertion(handle: false));
      expect(c.phase, isNot(NativeSessionPhase.signedIn));
      expect(paths, ['/auth/native/passkey/begin']);
    });
    test('opaque 401 keeps signed out, nothing stored', () async {
      final (c, _) = await run(assertion(), complete: 401);
      expect(c.phase, isNot(NativeSessionPhase.signedIn));
      expect(c.lastError, 'invalid_grant');
      expect(st.id, isNull);
    });
  });
}

class _Pk implements PasskeyAssertionSource {
  _Pk(this.raw);
  final String? raw;
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async => raw;
}
