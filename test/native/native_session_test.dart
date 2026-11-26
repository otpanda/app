import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
  Future<void> deleteKey() async => deleted = true;
  bool deleted = false;
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
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _G implements GoogleIdTokenSource {
  @override
  bool get available => true;
  @override
  Future<String?> idToken({required String nonce}) async => 't';
}

void main() {
  late _Ks ks;
  late _St st;
  late Map<String, ({int status, Map<String, dynamic>? body})> routes;
  late List<String> paths;
  var now = DateTime.fromMillisecondsSinceEpoch(1000000);

  NativeSessionController make() => NativeSessionController(
    NativeAuth(
      post: (p, b) async {
        paths.add(p);
        return routes[p] ?? (status: 404, body: null);
      },
      keystore: ks,
      browser: _Br(),
      google: _G(),
      store: st,
      apiOrigin: 'https://api.example',
      launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
    ),
    clock: () => now,
  );

  setUp(() {
    ks = _Ks();
    st = _St();
    paths = [];
    routes = {
      '/auth/native/challenge': (
        status: 200,
        body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
      ),
    };
  });

  test('start: nothing stored is signedOut without any network call', () async {
    final c = make();
    await c.start();
    expect(c.phase, NativeSessionPhase.signedOut);
    expect(paths, isEmpty);
  });

  test(
    'start renews from the stored device; accessToken reuses while fresh',
    () async {
      st.id = 'DEV';
      routes['/auth/native/renew'] = (
        status: 200,
        body: {
          'access': 'A1',
          'access_expires_at': now.millisecondsSinceEpoch + 300000,
        },
      );
      final c = make();
      await c.start();
      expect(c.phase, NativeSessionPhase.signedIn);
      paths.clear();
      expect(await c.accessToken(), 'A1');
      expect(paths, isEmpty);
      now = now.add(const Duration(seconds: 250)); // < 60 s left
      routes['/auth/native/renew'] = (
        status: 200,
        body: {
          'access': 'A2',
          'access_expires_at': now.millisecondsSinceEpoch + 300000,
        },
      );
      expect(await c.accessToken(), 'A2');
    },
  );

  test(
    'two 401s: sign-in required, key and id kept; outage: offline, kept',
    () async {
      st.id = 'DEV';
      routes['/auth/native/renew'] = (
        status: 401,
        body: {'error': 'invalid_grant'},
      );
      final c = make();
      await c.start();
      expect(c.phase, NativeSessionPhase.signInRequired);
      expect(st.id, 'DEV');
      expect(ks.deleted, isFalse);
      routes['/auth/native/renew'] = (status: 503, body: null);
      await c.start();
      expect(c.phase, NativeSessionPhase.offline);
      expect(st.id, 'DEV');
    },
  );

  test(
    'google browser_required falls back to browser (cancelled here)',
    () async {
      routes['/auth/native/google/begin'] = (
        status: 200,
        body: {'nonce': 'N', 'expires_at': 9},
      );
      routes['/auth/native/google/complete'] = (
        status: 409,
        body: {'error': 'browser_required'},
      );
      final c = make();
      await c.start();
      await c.signInWithGoogle();
      expect(c.phase, NativeSessionPhase.signedOut);
      expect(c.lastError, 'cancelled'); // browser path reached, user cancelled
    },
  );

  test('signOut: failure keeps signedIn state; 204 signs out', () async {
    st.id = 'DEV';
    routes['/auth/native/renew'] = (
      status: 200,
      body: {
        'access': 'A',
        'access_expires_at': now.millisecondsSinceEpoch + 300000,
      },
    );
    final c = make();
    await c.start();
    routes['/auth/native/logout'] = (status: 401, body: null);
    await c.signOut();
    expect(c.phase, NativeSessionPhase.signedIn);
    expect(c.lastError, 'invalid_grant');
    routes['/auth/native/logout'] = (status: 204, body: null);
    await c.signOut();
    expect(c.phase, NativeSessionPhase.signedOut);
    expect(st.id, isNull);
  });
}
