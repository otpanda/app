import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_read_contract.dart';

class Transport implements SessionTransport {
  final Future<SessionResponse> Function(String) handler;
  Transport(this.handler);
  @override
  Future<SessionResponse> getManagement(String path) => handler(path);
  @override
  Future<void> close() async {}
}

Map<String, dynamic> record([String id = 'entry']) => {
  'entryId': id,
  'code': '001234',
  'period': 30,
  'validFrom': 30,
  'validUntil': 60,
  'serverNow': 59000,
};
SessionResponse ok(Object o) => SessionResponse(200, jsonEncode(o));
SessionResponse session([int expires = 90000]) =>
    ok({'ownerId': 'owner', 'expiresAt': expires});
void main() {
  test('server timestamp contract and strict malformed response rejection', () {
    final c = GeneratedTotp.fromJson(record());
    expect(c.value, '001234');
    expect(c.serverNow, 59000);
    expect(c.toString(), 'GeneratedTotp(redacted)');
    for (final change in <Map<String, dynamic>>[
      {'entryId': ''},
      {'entryId': 'bad id'},
      {'code': '1234567'},
      {'code': null},
      {'period': '30'},
      {'period': 30.5},
      {'period': 0},
      {'period': 86401},
      {'validFrom': 31},
      {'validUntil': 61},
      {'validUntil': 9007199254740992},
      {'serverNow': 29999},
      {'serverNow': 60000},
      {'serverNow': -1},
      {'serverNow': null},
      {'seed': 'synthetic'},
    ]) {
      expect(
        () => GeneratedTotp.fromJson({...record(), ...change}),
        throwsFormatException,
      );
    }
  });
  test('time anchoring ignores wall clock and conservatively subtracts full elapsed request', () async {
    var tick = 100;
    final paths = <String>[];
    final store = TotpReadStore(
      Transport((p) async {
        paths.add(p);
        tick += 100;
        return p.endsWith('/session') ? session() : ok(record('a&b'));
      }),
      monotonicMilliseconds: () => tick,
    );
    await store.load('a&b');
    expect(paths, ['/v1/manage/session', '/v1/manage/totp-code?entry=a%26b']);
    expect(store.visible()?.value, '001234');
    expect(store.remainingSeconds(), 1);
    tick = 1099;
    expect(store.visible(), isNotNull);
    tick = 1100;
    expect(store.visible(), null);
    expect(store.remainingSeconds(), 0);
  });
  test(
    'session lifetime clamps server code lifetime and exact boundary expires',
    () async {
      var tick = 0;
      final store = TotpReadStore(
        Transport(
          (p) async => p.endsWith('/session') ? session(59500) : ok(record()),
        ),
        monotonicMilliseconds: () => tick,
      );
      await store.load('entry');
      tick = 499;
      expect(store.visible(), isNotNull);
      tick = 500;
      expect(store.visible(), null);
    },
  );
  test(
    'overslow request, expiry, clock rollback and invalid ticks fail closed',
    () async {
      for (final elapsed in [1000, 2000]) {
        var tick = 0;
        final store = TotpReadStore(
          Transport((p) async {
            if (p.endsWith('/session')) {
              return session();
            }
            tick = elapsed;
            return ok(record());
          }),
          monotonicMilliseconds: () => tick,
        );
        await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
        expect(store.visible(), null);
      }
      var tick = 100;
      final store = TotpReadStore(
        Transport(
          (p) async => p.endsWith('/session') ? session() : ok(record()),
        ),
        monotonicMilliseconds: () => tick,
      );
      await store.load('entry');
      tick = 99;
      expect(store.visible(), null);
      tick = 100;
      expect(store.visible(), null);
    },
  );
  test(
    'clear during either await discards completion and stops further work',
    () async {
      for (final stage in ['session', 'code']) {
        final pending = Completer<SessionResponse>();
        var calls = 0;
        final store = TotpReadStore(
          Transport((p) async {
            calls++;
            return (p.endsWith('/session') && stage == 'session') ||
                    (!p.endsWith('/session') && stage == 'code')
                ? pending.future
                : session();
          }),
          monotonicMilliseconds: () => 0,
        );
        final load = store.load('entry');
        await Future<void>.delayed(Duration.zero);
        store.clear();
        pending.complete(stage == 'session' ? session() : ok(record()));
        await load;
        expect(calls, stage == 'session' ? 1 : 2);
        expect(store.visible(), null);
      }
    },
  );
  test(
    'older success and failure cannot overwrite newer same-entry load',
    () async {
      for (final fail in [false, true]) {
        final old = Completer<SessionResponse>();
        var reads = 0;
        final store = TotpReadStore(
          Transport((p) async {
            if (p.endsWith('/session')) {
              return session();
            }
            return ++reads == 1 ? old.future : ok(record());
          }),
          monotonicMilliseconds: () => 0,
        );
        final first = store.load('entry');
        await Future<void>.delayed(Duration.zero);
        await store.load('entry');
        if (fail) {
          old.completeError(StateError('synthetic private'));
        } else {
          old.complete(ok(record('other')));
        }
        await first;
        expect(store.visible()?.entryId, 'entry');
      }
    },
  );
  test('bad session, wrong entry, malformed/oversized and HTTP failures clear without retry', () async {
    for (final body in <Object>[
      {},
      {'expiresAt': 90000},
      {'ownerId': 'owner'},
      {'ownerId': 'owner', 'expiresAt': '90000'},
    ]) {
      var calls = 0;
      final store = TotpReadStore(
        Transport((p) async {
          calls++;
          return ok(body);
        }),
        monotonicMilliseconds: () => 0,
      );
      await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
      expect(calls, 1);
      expect(store.visible(), null);
    }
    for (final r in [
      ok(record('other')),
      const SessionResponse(200, 'private'),
      SessionResponse(200, ' ' * 4097),
      const SessionResponse(401, 'private'),
      const SessionResponse(429, 'private'),
      const SessionResponse(503, 'private'),
    ]) {
      var calls = 0;
      final store = TotpReadStore(
        Transport((p) async {
          calls++;
          return p.endsWith('/session') ? session() : r;
        }),
        monotonicMilliseconds: () => 0,
      );
      await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
      expect(calls, 2);
      expect(store.visible(), null);
    }
  });
  test('invalid tick or expired session fails and empty visible does not cancel load', () async {
    for (final expiry in [59000, 58999]) {
      final store = TotpReadStore(
        Transport(
          (p) async => p.endsWith('/session') ? session(expiry) : ok(record()),
        ),
        monotonicMilliseconds: () => 0,
      );
      await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
      expect(store.visible(), null);
    }
    final pending = Completer<SessionResponse>();
    var tick = 0;
    final store = TotpReadStore(
      Transport(
        (p) async => p.endsWith('/session') ? session() : pending.future,
      ),
      monotonicMilliseconds: () => tick,
    );
    final load = store.load('entry');
    await Future<void>.delayed(Duration.zero);
    expect(store.visible(), null);
    pending.complete(ok(record()));
    await load;
    expect(store.visible(), isNotNull);
    tick = -1;
    expect(store.visible(), null);
  });
  test('negative start rejected before transport and rebuilt store recovers restarted clock', () async {
    var tick = -1, calls = 0;
    final transport = Transport((p) async {
      calls++;
      return p.endsWith('/session') ? session() : ok(record());
    });
    final store = TotpReadStore(transport, monotonicMilliseconds: () => tick);
    await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
    expect(calls, 0);
    tick = 100;
    await store.load('entry');
    expect(store.visible(), isNotNull);
    tick = 50;
    calls = 0;
    await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
    expect(calls, 0);
    final rebuilt = TotpReadStore(transport, monotonicMilliseconds: () => tick);
    await rebuilt.load('entry');
    expect(rebuilt.visible(), isNotNull);
  });
  test(
    'backward tick during response rejects instead of extending deadline',
    () async {
      var tick = 100;
      final store = TotpReadStore(
        Transport((p) async {
          if (p.endsWith('/session')) {
            return session();
          }
          tick = 99;
          return ok(record());
        }),
        monotonicMilliseconds: () => tick,
      );
      await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
      expect(store.visible(), null);
    },
  );
  test(
    'negative in-flight tick rejects and slow session consumes validity budget',
    () async {
      for (final delay in [-1, 1000]) {
        var tick = 0;
        var requests = 0;
        final store = TotpReadStore(
          Transport((p) async {
            requests++;
            if (p.endsWith('/session')) {
              tick = delay;
              return session();
            }
            return ok(record());
          }),
          monotonicMilliseconds: () => tick,
        );
        await expectLater(store.load('entry'), throwsA(isA<ClientFailure>()));
        expect(requests, 2);
        expect(store.visible(), null);
      }
    },
  );
  test('invalid visibility tick cancels a pending newer load', () async {
    final pending = Completer<SessionResponse>();
    var tick = 0;
    final store = TotpReadStore(
      Transport(
        (p) async => p.endsWith('/session') ? session() : pending.future,
      ),
      monotonicMilliseconds: () => tick,
    );
    final load = store.load('entry');
    await Future<void>.delayed(Duration.zero);
    tick = -1;
    expect(store.visible(), null);
    tick = 0;
    pending.complete(ok(record()));
    await load;
    expect(store.visible(), null);
  });
}
