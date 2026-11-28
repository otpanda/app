import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_realtime.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';

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

class _TokenBoundaryController extends NativeSessionController {
  _TokenBoundaryController(super.auth);
  bool cross = false;
  Future<void> Function()? boundary;
  @override
  Future<String?> accessToken() async {
    final token = await super.accessToken();
    if (cross) {
      await forceRenew();
    }
    await boundary?.call();
    return token;
  }
}

void main() {
  late int renews;
  late int renewStatus;
  late List<String> seenBearers;
  late List<int> apiStatuses;

  Future<NativeSessionController> signedIn() async {
    final c = NativeSessionController(
      NativeAuth(
        post: (p, b) async {
          if (p == '/auth/native/challenge') {
            return (
              status: 200,
              body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
            );
          }
          if (p == '/auth/native/renew') {
            renews++;
            return renewStatus == 200
                ? (
                    status: 200,
                    body: {
                      'access': 'tok$renews',
                      'access_expires_at': 9999999999999,
                    },
                  )
                : (status: renewStatus, body: null);
          }
          return (status: 404, body: null);
        },
        keystore: _Ks(),
        browser: _Br(),
        google: _G(),
        store: _St(),
        apiOrigin: 'https://api.example',
        launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
      ),
    );
    await c.start();
    return c;
  }

  NativeSessionBridge bridgeFor(NativeSessionController c) =>
      NativeSessionBridge(c, (m, p, {body, query, required bearer}) async {
        seenBearers.add('$m $p $bearer');
        final s = apiStatuses.isEmpty ? 200 : apiStatuses.removeAt(0);
        return SessionResponse(s, '{"ok":true}');
      });

  setUp(() {
    renews = 0;
    renewStatus = 200;
    seenBearers = [];
    apiStatuses = [];
  });

  test(
    'sharing successful same-device renewal sends once with stable epoch',
    () async {
      final original = await signedIn();
      final c = _TokenBoundaryController(original.auth);
      await c.start();
      final epoch = c.identityEpoch;
      c.cross = true;
      var calls = 0;
      final bridge = NativeSessionBridge(c, (
        m,
        p, {
        body,
        query,
        required bearer,
      }) async {
        calls++;
        return const SessionResponse(200, '{}');
      });
      final r = await bridge.sharingPost(
        '/v1/manage/sharing/contacts/list',
        {},
      );
      expect(r.status, 200);
      expect(calls, 1);
      expect(c.identityEpoch, epoch);
      expect(c.session?.deviceId, 'DEV');
    },
  );

  test(
    'sharing device retirement during token await refuses captured bearer',
    () async {
      final store = _St();
      // Native sessions carry no account id. A server-issued device id is bound
      // to one owner; a different device id is the supported account boundary.
      final auth = NativeAuth(
        post: (p, b) async => p == '/auth/native/challenge'
            ? (
                status: 200,
                body: {
                  'device_id': b['device_id'],
                  'nonce': 'n',
                  'expires_at': 5,
                },
              )
            : (
                status: 200,
                body: {'access': 'fixture', 'access_expires_at': 9999999999999},
              ),
        keystore: _Ks(),
        browser: _Br(),
        google: _G(),
        store: store,
        apiOrigin: 'https://api.example',
        launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
      );
      final c = _TokenBoundaryController(auth);
      await c.start();
      final epoch = c.identityEpoch;
      c.boundary = () async {
        store.id = 'OTHER_DEVICE';
        await c.forceRenew();
      };
      var calls = 0;
      final bridge = NativeSessionBridge(c, (
        m,
        p, {
        body,
        query,
        required bearer,
      }) async {
        calls++;
        return const SessionResponse(200, '{}');
      });
      final r = await bridge.sharingPost(
        '/v1/manage/sharing/contacts/list',
        {},
      );
      expect(r.status, 503);
      expect(calls, 0);
      expect(c.identityEpoch, greaterThan(epoch));
      expect(c.session?.deviceId, 'OTHER_DEVICE');
    },
  );

  test('sharing token await crossing identity sends no request', () async {
    final original = await signedIn();
    final c = _TokenBoundaryController(original.auth);
    await c.start();
    final epoch = c.identityEpoch;
    c.cross = true;
    renewStatus = 401;
    var calls = 0;
    final bridge = NativeSessionBridge(c, (
      m,
      p, {
      body,
      query,
      required bearer,
    }) async {
      calls++;
      return const SessionResponse(200, '{}');
    });
    final r = await bridge.sharingPost('/v1/manage/sharing/contacts/list', {
      'token': 'A' * 32,
    });
    expect(r.status, 503);
    expect(calls, 0);
    expect(c.identityEpoch, greaterThan(epoch));
  });

  test(
    'transfer response survives same-device access renewal without replay',
    () async {
      final c = await signedIn();
      final epoch = c.identityEpoch;
      var calls = 0;
      final bridge = NativeSessionBridge(c, (
        m,
        p, {
        body,
        query,
        required bearer,
      }) async {
        calls++;
        await c.forceRenew();
        return const SessionResponse(200, '{"status":"fenced"}');
      });
      final r = await bridge.transferPost('/v1/manage/totp/batch-outcome', {
        'protocol': 2,
        'admissionId': 'B' * 32,
        'batchNonce': 'v2:${'A' * 32}',
        'fence': true,
      });
      expect(r.status, 200);
      expect(r.body?['status'], 'fenced');
      expect(calls, 1);
      expect(c.identityEpoch, epoch);
    },
  );

  test(
    'transfer response refuses a retired identity epoch without replay',
    () async {
      final c = await signedIn();
      final epoch = c.identityEpoch;
      var calls = 0;
      final bridge = NativeSessionBridge(c, (
        m,
        p, {
        body,
        query,
        required bearer,
      }) async {
        calls++;
        renewStatus = 401;
        await c.forceRenew();
        return const SessionResponse(
          200,
          '{"status":"saved","entryIds":["one"]}',
        );
      });
      final r = await bridge.transferPost('/v1/manage/totp/batch-outcome', {
        'protocol': 2,
        'admissionId': 'B' * 32,
        'batchNonce': 'v2:${'A' * 32}',
        'fence': true,
      });
      expect(r.status, 503);
      expect(r.body, null);
      expect(calls, 1);
      expect(c.identityEpoch, greaterThan(epoch));
    },
  );

  test('transfer token await crossing identity sends no request', () async {
    final original = await signedIn();
    final c = _TokenBoundaryController(original.auth);
    await c.start();
    final epoch = c.identityEpoch;
    c.cross = true;
    renewStatus = 401;
    var calls = 0;
    final bridge = NativeSessionBridge(c, (
      m,
      p, {
      body,
      query,
      required bearer,
    }) async {
      calls++;
      return const SessionResponse(200, '{}');
    });
    final r = await bridge.transferPost('/v1/manage/totp/batch-outcome', {
      'protocol': 2,
      'admissionId': 'B' * 32,
      'batchNonce': 'v2:${'A' * 32}',
      'fence': true,
    });
    expect(r.status, 503);
    expect(calls, 0);
    expect(c.identityEpoch, greaterThan(epoch));
  });

  test('entry edit: exact bodies, typed ok only, no repeat on failure', () async {
    final c = await signedIn();
    final sent = <String>[];
    var res = const SessionResponse(200, '{"ok":true}');
    final b = NativeSessionBridge(c, (
      m,
      p, {
      body,
      query,
      required bearer,
    }) async {
      sent.add('$m $p $body');
      return res;
    });
    await b.renameEntry('E1', '  Work GitHub ');
    await b.updateAccount('E1', ' me@x.io ');
    await b.updateAccount('E1', null);
    expect(sent, [
      'POST /v1/manage/entry/rename {"entryId":"E1","label":"Work GitHub"}',
      'POST /v1/manage/entry/account {"entryId":"E1","accountName":"me@x.io"}',
      'POST /v1/manage/entry/account {"entryId":"E1","accountName":null}',
    ]);
    sent.clear();
    for (final r in [
      const SessionResponse(200, '{"ok":false}'),
      const SessionResponse(200, 'nope'),
      const SessionResponse(404, '{"error":"not_found"}'),
      const SessionResponse(500, '{"ok":true}'),
    ]) {
      res = r;
      await expectLater(b.renameEntry('E1', 'x'), throwsStateError);
    }
    expect(sent.length, 4, reason: 'one request each, none repeated');
    sent.clear();
    for (final f in [
      () => b.renameEntry('E1', '   '),
      () => b.renameEntry('E1', 'x' * 121),
      () => b.renameEntry('bad id', 'x'),
      () => b.renameEntry('', 'x'),
      () => b.updateAccount('E1', ''),
      () => b.updateAccount('E1', 'y' * 121),
    ]) {
      await expectLater(f(), throwsStateError);
    }
    expect(sent, isEmpty);
  });

  test(
    'describe: exact body, retry backoff, resend on label or session change',
    () async {
      final c = await signedIn();
      final sent = <String>[];
      var status = 500;
      var label = "  Abraham's Pixel 8a ";
      var clock = 1000000;
      final b = NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async {
          sent.add('$m $p $body');
          return SessionResponse(status, '{"ok":true}');
        },
        deviceLabel: () async => label,
        now: () => clock,
      );
      Future<void> tick() async {
        await b.maintain();
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      await tick();
      expect(sent, [
        'POST /v1/manage/session/describe {"browser":null,"os":"android","name":"Abraham\'s Pixel 8a"}',
      ]);
      await tick();
      expect(sent.length, 1, reason: 'backoff after a 500');
      clock += 61000;
      status = 200;
      await tick();
      expect(sent.length, 2);
      await tick();
      expect(sent.length, 2, reason: 'same session and label');
      label = '';
      await tick();
      expect(
        sent.last,
        'POST /v1/manage/session/describe {"browser":null,"os":"android","name":null}',
      );
      expect(sent.length, 3);
      b.logout();
      await tick();
      expect(sent.length, 4, reason: 'session change resends the same label');
    },
  );

  test('400/403/405 stop retrying for that session and label', () async {
    for (final st in [400, 403, 405]) {
      final c = await signedIn();
      var n = 0;
      final b = NativeSessionBridge(c, (
        m,
        p, {
        body,
        query,
        required bearer,
      }) async {
        n++;
        return SessionResponse(st, '{}');
      }, deviceLabel: () async => 'Pixel');
      for (var i = 0; i < 4; i++) {
        await b.maintain();
        for (var j = 0; j < 5; j++) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      expect(n, 1, reason: 'status $st');
    }
  });

  test('a label source that never completes does not block maintain', () async {
    final c = await signedIn();
    var calls = 0;
    final never = Completer<String?>();
    final b = NativeSessionBridge(
      c,
      (m, p, {body, query, required bearer}) async {
        return const SessionResponse(200, '{}');
      },
      deviceLabel: () {
        calls++;
        return never.future;
      },
    );
    await b.maintain().timeout(const Duration(seconds: 1));
    await b.maintain().timeout(const Duration(seconds: 1));
    expect(calls, 1, reason: 'one attempt in flight, maintain returned');
  });

  test('label cap is by code point', () {
    final long = '${'a' * 39}😀😀';
    expect(cappedDeviceLabel(long)!.runes.length, 40);
    expect(cappedDeviceLabel(long)!.endsWith('😀'), isTrue);
    expect(cappedDeviceLabel('  '), isNull);
  });

  test('without a label source nothing is described', () async {
    final c = await signedIn();
    final sent = <String>[];
    final b = NativeSessionBridge(c, (
      m,
      p, {
      body,
      query,
      required bearer,
    }) async {
      sent.add(p);
      return const SessionResponse(200, '{}');
    });
    await b.maintain();
    expect(sent, isEmpty);
  });

  test(
    'status mirrors the session and read uses the bearer on allow-listed paths',
    () async {
      final c = await signedIn();
      final b = bridgeFor(c);
      expect(b.status, 'restored');
      final r = await b.read('/v1/manage/account');
      expect(r.status, 200);
      expect(seenBearers.single, 'GET /v1/manage/account tok1');
      expect(() => b.read('/v1/manage/other'), throwsStateError);
      expect(() => b.organize('DELETE', ''), throwsStateError);
      expect(() => b.organize('GET', 'x'), throwsStateError);
    },
  );

  test(
    '401 renews once and retries; a second 401 is paused (503), not signed out',
    () async {
      final c = await signedIn();
      final b = bridgeFor(c);
      apiStatuses = [401, 200];
      expect((await b.read('/v1/manage/entries')).status, 200);
      expect(seenBearers.last, endsWith('tok2'));
      apiStatuses = [401, 401];
      expect((await b.read('/v1/manage/entries')).status, 503);
      expect(c.phase, NativeSessionPhase.signedIn);
    },
  );

  test(
    'signed out gives 401 without any API call; offline gives 503',
    () async {
      final c = NativeSessionController(
        NativeAuth(
          post: (p, b) async => (status: 503, body: null),
          keystore: _Ks(),
          browser: _Br(),
          google: _G(),
          store: _St(),
          apiOrigin: 'https://api.example',
          launchUrl: (c, s) => Uri.parse('https://x/'),
        ),
      );
      await c.start();
      expect(c.phase, NativeSessionPhase.offline);
      final b = bridgeFor(c);
      expect((await b.read('/v1/manage/account')).status, 503);
      expect(b.status, 'session-paused');
      expect(seenBearers, isEmpty);
      expect(() => b.addTotp('a', 'b', 'c'), throwsStateError);
    },
  );

  test('bearer request: Authorization, no Origin or Cookie, query, size cap, no redirect', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    final seen = <Map<String, Object?>>[];
    server.listen((r) async {
      await utf8.decodeStream(r);
      seen.add({
        'auth': r.headers.value('authorization'),
        'origin': r.headers.value('origin'),
        'cookie': r.headers.value('cookie'),
        'q': r.uri.query,
        'path': r.uri.path,
      });
      if (r.uri.path == '/big') {
        r.response.write('x' * 2000);
      } else if (r.uri.path == '/redir') {
        r.response.statusCode = 302;
        r.response.headers.set('location', '/v1/manage/account');
      } else {
        r.response.write('{"a":1}');
      }
      await r.response.close();
    });
    final o = 'http://127.0.0.1:${server.port}';
    final call = androidBearerRequest(
      o,
      maxBytes: 1000,
      deadline: const Duration(seconds: 3),
    );
    final ok = await call(
      'GET',
      '/v1/manage/totp-code',
      query: {'entry': 'e 1'},
      bearer: 'T',
    );
    expect(ok.status, 200);
    expect(ok.body, '{"a":1}');
    expect(seen.single['auth'], 'Bearer T');
    expect(seen.single['origin'], isNull);
    expect(seen.single['cookie'], isNull);
    expect(seen.single['q'], 'entry=e+1');
    await expectLater(
      call('GET', '/big', bearer: 'T'),
      throwsA(isA<FormatException>()),
    );
    expect((await call('GET', '/redir', bearer: 'T')).status, 302);
    expect(seen.where((s) => s['path'] == '/v1/manage/account'), isEmpty);
  });

  group('realtime ticket through the bridge', () {
    NativeSessionBridge rt(
      NativeSessionController c,
      List<String> log,
      List<SessionResponse> answers,
      Future<RealtimeSocket> Function(List<String>) connect,
    ) => NativeSessionBridge(c, (m, p, {body, query, required bearer}) async {
      log.add('$m $p $bearer ${body ?? ''}');
      return answers.isEmpty
          ? const SessionResponse(200, '{}')
          : answers.removeAt(0);
    }, realtimeConnector: connect);

    test('mints with the bearer, empty body, no Origin; connects with subprotocols', () async {
      final c = await signedIn();
      final log = <String>[];
      final protos = <List<String>>[];
      final b = rt(
        c,
        log,
        [
          SessionResponse(
            200,
            jsonEncode({'ticket': 'rt1.${'A' * 16}.${'B' * 43}'}),
          ),
        ],
        (p) async {
          protos.add(p);
          return _NoSock();
        },
      );
      final got = <String>[];
      final stop = b.realtimeSubscribe(got.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(log.single, 'POST /auth/realtime/ticket tok1 ');
      expect(protos.single.first, 'otpanda.v1');
      expect(got, ['connect']);
      stop();
      b.disposeRealtime();
    });

    test(
      'a second 401 after renewal ends realtime: no lost, no endless requests',
      () async {
        final c = await signedIn();
        final log = <String>[];
        final b = rt(c, log, [
          const SessionResponse(401, '{}'),
          const SessionResponse(401, '{}'),
        ], (p) async => _NoSock());
        final got = <String>[];
        b.realtimeSubscribe(got.add);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(log.length, 2);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(log.length, 2);
        expect(got, isEmpty);
        b.disposeRealtime();
      },
    );

    test(
      'signing out tears realtime down and signing back in reconnects',
      () async {
        final c = await signedIn();
        final log = <String>[];
        var sockets = 0;
        final b = rt(c, log, [], (p) async {
          sockets++;
          return _NoSock();
        });
        final got = <String>[];
        b.realtimeSubscribe(got.add);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          sockets,
          0,
          reason: 'default ticket body {} is malformed: counted failure, never a socket',
        );
        await c.signOut();
        final n = log.length;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(log.length, n);
        b.disposeRealtime();
      },
    );
  });

  test('parseRetryAfter reads seconds and HTTP-dates, junk and past dates are null', () {
    final now = DateTime.utc(2026, 11, 25, 12, 0, 0);
    DateTime clock() => now;
    expect(parseRetryAfter('90', now: clock), 90);
    expect(parseRetryAfter(' 7 ', now: clock), 7);
    expect(parseRetryAfter('Wed, 25 Nov 2026 12:01:30 GMT', now: clock), 90);
    expect(
      parseRetryAfter('Wednesday, 25-Nov-26 12:00:45 GMT', now: clock),
      45,
    );
    expect(parseRetryAfter('Wed Nov 25 12:00:20 2026', now: clock), 20);
    expect(
      parseRetryAfter('Wed, 25 Nov 2026 11:59:00 GMT', now: clock),
      isNull,
    );
    expect(parseRetryAfter('soon', now: clock), isNull);
    expect(parseRetryAfter('-5', now: clock), isNull);
    expect(parseRetryAfter('1234567', now: clock), isNull);
    expect(parseRetryAfter(null, now: clock), isNull);
  });

  test('a double-401 end does not request again on foreground; a renewed token does', () async {
    final c = await signedIn();
    final log = <String>[];
    final b = NativeSessionBridge(c, (
      m,
      p, {
      body,
      query,
      required bearer,
    }) async {
      log.add('$m $p $bearer');
      return log.length <= 2
          ? const SessionResponse(401, '{}')
          : SessionResponse(
              200,
              jsonEncode({'ticket': 'rt1.${'A' * 16}.${'B' * 43}'}),
            );
    }, realtimeConnector: (p) async => _NoSock());
    final got = <String>[];
    b.realtimeSubscribe(got.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(log.length, 2);
    b.realtimeSetForeground(false);
    b.realtimeSetForeground(true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(log.length, 2, reason: 'same rejected session: no request');
    await c.forceRenew();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(log.length, 3, reason: 'renewed token: one request');
    expect(got, ['connect']);
    b.disposeRealtime();
  });
}

class _NoSock implements RealtimeSocket {
  @override
  String? get protocol => realtimeSubprotocol;
  @override
  Stream<String> get messages => const Stream<String>.empty();
  @override
  int? get closeCode => null;
  @override
  void close([int code = 1000]) {}
}
