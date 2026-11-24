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

Map<String, dynamic> record([String entry = 'entry']) => {
  'entryId': entry,
  'code': '94287082',
  'period': 30,
  'validFrom': 30,
  'validUntil': 60,
};
SessionResponse ok(Object o) => SessionResponse(200, jsonEncode(o));
void main() {
  test('seconds contract, exact rollover, leading zero and redaction', () {
    final c = GeneratedTotp.fromJson({...record(), 'code': '001234'});
    expect(c.value, '001234');
    expect(c.activeAtMilliseconds(29999), false);
    expect(c.activeAtMilliseconds(30000), true);
    expect(c.remainingSeconds(59000), 1);
    expect(c.remainingSeconds(59999), 1);
    expect(c.activeAtMilliseconds(60000), false);
    expect(c.remainingSeconds(60000), 0);
    expect(c.activeAtMilliseconds(-1), false);
    expect(c.toString(), 'GeneratedTotp(redacted)');
  });
  test('strict allowlist and bounded epoch/interval/code validation', () {
    for (final change in <Map<String, dynamic>>[
      {'entryId': ''},
      {'entryId': 'bad id'},
      {'code': '1234567'},
      {'code': '12345a'},
      {'period': 0},
      {'period': 86401},
      {'validFrom': 31},
      {'validUntil': 61},
      {'period': 30.5},
      {'validFrom': -30},
      {'validUntil': 9007199254740992},
      {'seed': 'synthetic'},
    ]) {
      expect(
        () => GeneratedTotp.fromJson({...record(), ...change}),
        throwsFormatException,
      );
    }
  });
  test('selected entry encoded, millisecond session expiry, clear', () async {
    final paths = <String>[];
    final store = TotpReadStore(
      Transport((path) async {
        paths.add(path);
        return path.endsWith('/session')
            ? ok({'ownerId': 'owner', 'expiresAt': 59950})
            : ok(record('a&b'));
      }),
    );
    await store.load('a&b', () => 59000);
    expect(paths, ['/v1/manage/session', '/v1/manage/totp-code?entry=a%26b']);
    expect(store.visible(59949)?.value, '94287082');
    expect(store.visible(59950), null);
    store.clear();
    expect(store.visible(59000), null);
  });
  test('clear while pending never restores code', () async {
    final pending = Completer<SessionResponse>();
    final store = TotpReadStore(
      Transport(
        (p) async => p.endsWith('/session')
            ? ok({'ownerId': 'owner', 'expiresAt': 90000})
            : pending.future,
      ),
    );
    final load = store.load('entry', () => 59000);
    await Future<void>.delayed(Duration.zero);
    store.clear();
    pending.complete(ok(record()));
    await load;
    expect(store.visible(59000), null);
  });
  test(
    'wrong entry, stale, oversized, malformed and errors clear without retry',
    () async {
      for (final response in [
        ok(record('other')),
        ok({...record(), 'validFrom': 0, 'validUntil': 30}),
        const SessionResponse(200, 'bad'),
        SessionResponse(200, ' ' * 4097),
        const SessionResponse(401, 'private'),
        const SessionResponse(403, 'private'),
        const SessionResponse(429, 'private'),
        const SessionResponse(503, 'private'),
      ]) {
        var requests = 0;
        final store = TotpReadStore(
          Transport((path) async {
            requests++;
            return path.endsWith('/session')
                ? ok({'ownerId': 'owner', 'expiresAt': 90000})
                : response;
          }),
        );
        await expectLater(
          store.load('entry', () => 59000),
          throwsA(isA<ClientFailure>()),
        );
        expect(requests, 2);
        expect(store.visible(59000), null);
      }
    },
  );
  test('newer selection wins when older reply completes later', () async {
    final old = Completer<SessionResponse>();
    final store = TotpReadStore(
      Transport((p) async {
        if (p.endsWith('/session')) {
          return ok({'ownerId': 'owner', 'expiresAt': 90000});
        }
        return p.endsWith('entry=old') ? old.future : ok(record('new'));
      }),
    );
    final first = store.load('old', () => 59000);
    await Future<void>.delayed(Duration.zero);
    await store.load('new', () => 59000);
    old.complete(ok(record('old')));
    await first;
    expect(store.visible(59000)?.entryId, 'new');
  });
  test(
    'rollover or session expiry while loading never releases code',
    () async {
      for (final expiry in [60000, 90000]) {
        var now = 59000;
        final store = TotpReadStore(
          Transport((p) async {
            if (p.endsWith('/session')) {
              return ok({'ownerId': 'owner', 'expiresAt': expiry});
            }
            now = 60000;
            return ok(record());
          }),
        );
        await expectLater(
          store.load('entry', () => now),
          throwsA(isA<ClientFailure>()),
        );
        expect(store.visible(now), null);
      }
    },
  );
  test('older failure cannot clear newer same-entry result', () async {
    final old = Completer<SessionResponse>();
    var reads = 0;
    final store = TotpReadStore(
      Transport((p) async {
        if (p.endsWith('/session')) {
          return ok({'ownerId': 'owner', 'expiresAt': 90000});
        }
        return ++reads == 1 ? old.future : ok(record());
      }),
    );
    final first = store.load('entry', () => 59000);
    await Future<void>.delayed(Duration.zero);
    await store.load('entry', () => 59000);
    old.completeError(StateError('synthetic private failure'));
    await first;
    expect(store.visible(59000)?.entryId, 'entry');
  });
  test('clear during session await prevents further requests', () async {
    final pending = Completer<SessionResponse>();
    var requests = 0;
    final store = TotpReadStore(
      Transport((p) {
        requests++;
        return pending.future;
      }),
    );
    final load = store.load('entry', () => 59000);
    store.clear();
    pending.complete(ok({'ownerId': 'owner', 'expiresAt': 90000}));
    await load;
    expect(requests, 1);
    expect(store.visible(59000), null);
  });
  test('malformed or expired session rejected before code request', () async {
    for (final body in <Object>[
      {},
      {'expiresAt': 90000},
      {'ownerId': 'owner'},
      {'ownerId': 'owner', 'expiresAt': 59000},
      {'ownerId': 'owner', 'expiresAt': '90000'},
    ]) {
      var requests = 0;
      final store = TotpReadStore(
        Transport((p) async {
          requests++;
          return ok(body);
        }),
      );
      await expectLater(
        store.load('entry', () => 59000),
        throwsA(isA<ClientFailure>()),
      );
      expect(requests, 1);
      expect(store.visible(59000), null);
    }
  });
  test(
    'wrong field types rejected and fixed string representations redacted',
    () async {
      for (final change in <Map<String, dynamic>>[
        {'period': '30'},
        {'code': null},
      ]) {
        final store = TotpReadStore(
          Transport(
            (p) async => p.endsWith('/session')
                ? ok({'ownerId': 'owner', 'expiresAt': 90000})
                : ok({...record(), ...change}),
          ),
        );
        await expectLater(
          store.load('entry', () => 59000),
          throwsA(isA<ClientFailure>()),
        );
        expect(store.visible(59000), null);
      }
      expect(
        const SessionResponse(200, 'private-code').toString(),
        isNot(contains('private-code')),
      );
      expect(const ClientFailure().toString(), isNot(contains('private-code')));
    },
  );
}
