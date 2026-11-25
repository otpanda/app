import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Key, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_app.dart';
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
  @override
  Future<Uri?> run(Uri u) async {
    runs++;
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
}
