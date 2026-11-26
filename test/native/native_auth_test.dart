import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_auth.dart';

const api = 'https://otpanda-api.abrahammurciano.workers.dev';

Uint8List hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

class FakeKeystore implements NativeKeystore {
  bool deleted = false;
  bool pending = false,
      committed = false,
      discarded = false,
      pendingExists = false;
  bool pendingSigned = false;
  Uint8List? lastMessage;
  late Uint8List der;
  @override
  Future<Uint8List> ensureKey() async =>
      Uint8List.fromList([4, ...List.filled(32, 1), ...List.filled(32, 2)]);
  @override
  Future<Uint8List> beginNewKey() async {
    pending = true;
    return ensureKey();
  }

  @override
  Future<void> commitNewKey() async => committed = true;
  @override
  Future<void> discardNewKey() async => discarded = true;
  @override
  Future<bool> hasPendingKey() async => pendingExists;
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async {
    if (pending) pendingSigned = true;
    lastMessage = m;
    return der;
  }

  @override
  Future<void> deleteKey() async => deleted = true;
}

class FakeStore implements NativeSecureStore {
  String? id;
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class FakeBrowser implements BrowserHandoff {
  Uri? opened;
  Uri? Function(Uri)? reply;
  @override
  Future<Uri?> run(Uri url) async {
    opened = url;
    return reply?.call(url);
  }
}

class FakeGoogle implements GoogleIdTokenSource {
  @override
  bool available = true;
  String? token = 'idtok';
  String? nonceSeen;
  @override
  Future<String?> idToken({required String nonce}) async {
    nonceSeen = nonce;
    return token;
  }
}

void main() {
  final v = jsonDecode(
    File('test/fixtures/native-vector.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final renew = (v['cases'] as Map)['renew'] as Map<String, dynamic>;

  late FakeKeystore ks;
  late FakeStore st;
  late FakeBrowser br;
  late FakeGoogle g;
  late List<(String, Map<String, dynamic>)> calls;
  late Map<String, ({int status, Map<String, dynamic>? body})> routes;

  NativeAuth make() => NativeAuth(
    post: (p, b) async {
      calls.add((p, b));
      return routes[p] ?? (status: 404, body: null);
    },
    keystore: ks,
    browser: br,
    google: g,
    store: st,
    apiOrigin: api,
    launchUrl: (c, s) => Uri.https('otpanda.github.io', '/app/', {
      'native_challenge': c,
      'native_state': s,
    }),
  );

  setUp(() {
    ks = FakeKeystore()..der = hex(renew['signature_der_hex'] as String);
    st = FakeStore();
    br = FakeBrowser();
    g = FakeGoogle();
    calls = [];
    routes = {};
  });

  test(
    'browser sign-in: exchange carries code, verifier matching challenge, key',
    () async {
      br.reply = (u) => Uri.parse(
        '$api/app-return#code=CODE&state=${u.queryParameters['native_state']}',
      );
      routes['/auth/native/exchange'] = (
        status: 200,
        body: {
          'device_id': 'AbCdEfGhIjKl',
          'access': 'tok',
          'access_expires_at': 5,
        },
      );
      final s = await make().signInWithBrowser();
      expect(s.deviceId, 'AbCdEfGhIjKl');
      expect(st.id, 'AbCdEfGhIjKl');
      expect(ks.pending && ks.committed && !ks.discarded, isTrue);
      final b = calls.single.$2;
      expect(b['code'], 'CODE');
      expect(b['redirect_uri'], '$api/app-return');
      expect((b['renewal_key'] as String).isNotEmpty, isTrue);
      expect(b.keys.toSet(), {
        'code',
        'verifier',
        'redirect_uri',
        'renewal_key',
      });
    },
  );

  test(
    'browser sign-in: wrong state, cancel, and 401 all fail without storing',
    () async {
      br.reply = (u) => Uri.parse('$api/app-return#code=C&state=bad');
      await expectLater(
        make().signInWithBrowser(),
        throwsA(
          isA<NativeAuthException>().having((e) => e.kind, 'kind', 'protocol'),
        ),
      );
      expect(calls, isEmpty);
      br.reply = (u) => null;
      await expectLater(
        make().signInWithBrowser(),
        throwsA(
          isA<NativeAuthException>().having((e) => e.kind, 'kind', 'cancelled'),
        ),
      );
      br.reply = (u) => Uri.parse(
        '$api/app-return#code=C&state=${u.queryParameters['native_state']}',
      );
      routes['/auth/native/exchange'] = (
        status: 401,
        body: {'error': 'invalid_grant'},
      );
      await expectLater(
        make().signInWithBrowser(),
        throwsA(
          isA<NativeAuthException>().having(
            (e) => e.kind,
            'kind',
            'invalid_grant',
          ),
        ),
      );
      expect(st.id, isNull);
      expect(ks.committed, isFalse);
      expect(ks.discarded, isTrue);
      expect(ks.deleted, isFalse);
    },
  );

  test(
    'google: nonce from begin goes to the token source, then complete',
    () async {
      routes['/auth/native/google/begin'] = (
        status: 200,
        body: {'nonce': 'N1', 'expires_at': 9},
      );
      routes['/auth/native/google/complete'] = (
        status: 200,
        body: {
          'device_id': 'AbCdEfGhIjKl',
          'access': 'a',
          'access_expires_at': 7,
        },
      );
      await make().signInWithGoogle();
      expect(g.nonceSeen, 'N1');
      expect(calls[0].$2, isEmpty);
      expect(calls[1].$2['id_token'], 'idtok');
      expect(st.id, 'AbCdEfGhIjKl');
    },
  );

  final grantTok = 'otpda_${'A' * 55}';
  Map<String, Object?> okBody([Map<String, Object?> extra = const {}]) => {
    'device_id': 'AbCdEfGhIjKl',
    'access': 'a',
    'access_expires_at': 7,
    ...extra,
  };

  test('enroll_grant: optional on exchange and google complete, absent means none, kept in memory only', () async {
    br.reply = (u) => Uri.parse(
      '$api/app-return#code=CODE&state=${u.queryParameters['native_state']}',
    );
    routes['/auth/native/exchange'] = (status: 200, body: okBody());
    expect((await make().signInWithBrowser()).enrollGrant, isNull);
    routes['/auth/native/exchange'] = (
      status: 200,
      body: okBody({'enroll_grant': grantTok, 'future_key': 1}),
    );
    final s = await make().signInWithBrowser();
    expect(s.enrollGrant, grantTok);
    routes['/auth/native/google/begin'] = (
      status: 200,
      body: {'nonce': 'N1', 'expires_at': 9},
    );
    routes['/auth/native/google/complete'] = (
      status: 200,
      body: okBody({'enroll_grant': grantTok}),
    );
    expect((await make().signInWithGoogle()).enrollGrant, grantTok);
  });

  test(
    'enroll_grant: null, wrong type or malformed is a protocol error',
    () async {
      routes['/auth/native/google/begin'] = (
        status: 200,
        body: {'nonce': 'N1', 'expires_at': 9},
      );
      for (final bad in <Object?>[
        null,
        5,
        'otpda_short',
        '${grantTok}x',
        'tok_${'A' * 55}',
      ]) {
        routes['/auth/native/google/complete'] = (
          status: 200,
          body: okBody({'enroll_grant': bad}),
        );
        await expectLater(
          make().signInWithGoogle(),
          throwsA(
            isA<NativeAuthException>().having(
              (e) => e.kind,
              'kind',
              'protocol',
            ),
          ),
        );
      }
    },
  );

  test('google: unavailable flavor, browser_required and cancel', () async {
    g.available = false;
    await expectLater(
      make().signInWithGoogle(),
      throwsA(
        isA<NativeAuthException>().having((e) => e.kind, 'kind', 'unavailable'),
      ),
    );
    g.available = true;
    routes['/auth/native/google/begin'] = (
      status: 200,
      body: {'nonce': 'N', 'expires_at': 9},
    );
    routes['/auth/native/google/complete'] = (
      status: 409,
      body: {'error': 'browser_required'},
    );
    await expectLater(
      make().signInWithGoogle(),
      throwsA(
        isA<NativeAuthException>().having(
          (e) => e.kind,
          'kind',
          'browser_required',
        ),
      ),
    );
    g.token = null;
    await expectLater(
      make().signInWithGoogle(),
      throwsA(
        isA<NativeAuthException>().having((e) => e.kind, 'kind', 'cancelled'),
      ),
    );
    expect(st.id, isNull);
  });

  test('renew signs the exact API message and sends raw r||s', () async {
    st.id = renew['device_id'] as String;
    routes['/auth/native/challenge'] = (
      status: 200,
      body: {
        'device_id': renew['device_id'],
        'nonce': renew['nonce'],
        'expires_at': renew['expires_at'],
      },
    );
    routes['/auth/native/renew'] = (
      status: 200,
      body: {'access': 'a2', 'access_expires_at': 11},
    );
    final s = await make().renew();
    expect(s!.access, 'a2');
    expect(utf8.decode(ks.lastMessage!), renew['message_utf8']);
    final b = calls[1].$2;
    expect(b['signature'], renew['signature_raw']);
    expect(b['purpose'], isNull);
    expect(calls[0].$2['purpose'], 'renew');
  });

  test('renew: signed out is null; 401 retries once and keeps the key; outage keeps it', () async {
    expect(await make().renew(), isNull);
    st.id = renew['device_id'] as String;
    routes['/auth/native/challenge'] = (
      status: 200,
      body: {
        'device_id': renew['device_id'],
        'nonce': renew['nonce'],
        'expires_at': renew['expires_at'],
      },
    );
    routes['/auth/native/renew'] = (status: 503, body: null);
    await expectLater(make().renew(), throwsA(isA<NativeAuthException>()));
    expect(st.id, isNotNull);
    expect(ks.deleted, isFalse);
    calls.clear();
    routes['/auth/native/renew'] = (
      status: 401,
      body: {'error': 'invalid_grant'},
    );
    await expectLater(
      make().renew(),
      throwsA(
        isA<NativeAuthException>().having(
          (e) => e.kind,
          'kind',
          'invalid_grant',
        ),
      ),
    );
    expect(calls.where((c) => c.$1 == '/auth/native/challenge'), hasLength(2));
    expect(st.id, isNotNull);
    expect(ks.deleted, isFalse);
  });

  test('logout clears local material only after server 204', () async {
    st.id = renew['device_id'] as String;
    routes['/auth/native/challenge'] = (
      status: 200,
      body: {
        'device_id': renew['device_id'],
        'nonce': renew['nonce'],
        'expires_at': renew['expires_at'],
      },
    );
    routes['/auth/native/logout'] = (status: 429, body: null);
    await expectLater(make().logout(), throwsA(isA<NativeAuthException>()));
    expect(st.id, isNotNull);
    routes['/auth/native/logout'] = (status: 401, body: null);
    await expectLater(make().logout(), throwsA(isA<NativeAuthException>()));
    expect(ks.deleted, isFalse);
    routes['/auth/native/logout'] = (status: 204, body: null);
    await make().logout();
    expect(st.id, isNull);
    expect(ks.deleted, isTrue);
  });
  test('parallel renew calls share one challenge and renew', () async {
    st.id = renew['device_id'] as String;
    routes['/auth/native/challenge'] = (
      status: 200,
      body: {
        'device_id': renew['device_id'],
        'nonce': renew['nonce'],
        'expires_at': renew['expires_at'],
      },
    );
    routes['/auth/native/renew'] = (
      status: 200,
      body: {'access': 'a', 'access_expires_at': 1},
    );
    final a = make();
    final r = await Future.wait([a.renew(), a.renew()]);
    expect(r[0], same(r[1]));
    expect(calls.where((c) => c.$1 == '/auth/native/renew'), hasLength(1));
    await a.renew();
    expect(calls.where((c) => c.$1 == '/auth/native/renew'), hasLength(2));
  });
  test(
    'concurrent sign-in is refused and cannot touch the first one\'s key',
    () async {
      final gate = Completer<Uri?>();
      br.reply = null;
      final slow = _SlowBrowser(gate);
      final a = NativeAuth(
        post: (p, b) async => routes[p] ?? (status: 404, body: null),
        keystore: ks,
        browser: slow,
        google: g,
        store: st,
        apiOrigin: api,
        launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
      );
      final first = a.signInWithBrowser();
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        a.signInWithBrowser(),
        throwsA(
          isA<NativeAuthException>().having((e) => e.kind, 'kind', 'busy'),
        ),
      );
      expect(ks.discarded, isFalse);
      gate.complete(null);
      await expectLater(first, throwsA(isA<NativeAuthException>()));
      expect(ks.discarded, isTrue);
    },
  );

  test(
    'crash after server accepted: device id kept, pending key recovers renew',
    () async {
      // Simulated state after a crash between writeDeviceId and commitNewKey.
      st.id = renew['device_id'] as String;
      ks.pendingExists = true;
      routes['/auth/native/challenge'] = (
        status: 200,
        body: {
          'device_id': renew['device_id'],
          'nonce': renew['nonce'],
          'expires_at': renew['expires_at'],
        },
      );
      var n = 0;
      final a = NativeAuth(
        post: (p, b) async {
          if (p == '/auth/native/renew') {
            n++;
            // Active (old) key is rejected twice; the pending key is accepted.
            return n <= 2
                ? (status: 401, body: {'error': 'invalid_grant'})
                : (status: 200, body: {'access': 'ok', 'access_expires_at': 3});
          }
          return routes[p] ?? (status: 404, body: null);
        },
        keystore: ks,
        browser: br,
        google: g,
        store: st,
        apiOrigin: api,
        launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
      );
      final s = await a.renew();
      expect(s!.access, 'ok');
      expect(ks.pendingSigned, isTrue);
      expect(ks.committed, isTrue);
      expect(ks.deleted, isFalse);
    },
  );
}

class _SlowBrowser implements BrowserHandoff {
  _SlowBrowser(this.gate);
  final Completer<Uri?> gate;
  @override
  Future<Uri?> run(Uri url) => gate.future;
}
