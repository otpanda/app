import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_batch.dart';

// Server time is far from any device clock on purpose.
const serverStart = 1800000010000; // ms, 10 s after a 30 s boundary
String body({
  int serverNow = serverStart,
  int window = 600,
  List<Map<String, Object?>>? entries,
  List<Map<String, Object?>> omitted = const [],
}) => jsonEncode({
  'serverNow': serverNow,
  'windowSeconds': window,
  'windowExpiresAt': serverNow ~/ 1000 * 1000 + window * 1000,
  'entries':
      entries ??
      [
        {
          'entryId': 'a',
          'period': 30,
          'digits': 6,
          'validFrom': (serverNow ~/ 1000) ~/ 30 * 30,
          'codes': [for (var i = 0; i < 21; i++) '${100000 + i}'],
        },
      ],
  'omitted': omitted,
});

class Rig {
  int now = 1000;
  int wall = 5000000;
  int session = 3600000; // ms of session left at this.now
  final calls = <List<String>>[];
  Future<SessionResponse> Function(List<String>) respond = (_) async =>
      SessionResponse(200, body());
  late final store = TotpBatchStore(
    fetch: (ids) {
      calls.add(ids);
      return respond(ids);
    },
    monotonicMilliseconds: () => now,
    wallMilliseconds: () => wall,
    sessionExpiresAt: () async => serverStart + session,
  );
}

void main() {
  test(
    'per-id backoff suppresses empty chains and session HTTP reads',
    () async {
      var reads = 0, now = 1000;
      final store = TotpBatchStore(
        fetch: (_) async => SessionResponse(400, '{}'),
        monotonicMilliseconds: () => now,
        wallMilliseconds: () => now,
        sessionExpiresAt: () async {
          reads++;
          return serverStart + 3600000;
        },
      );
      await store.ensure(['a']);
      expect(reads, 1);
      expect(store.needsFetch(['a']), isFalse);
      for (var i = 0; i < 10; i++) {
        await store.ensure(['a']);
      }
      expect(reads, 1);
      now += 10000;
      expect(store.needsFetch(['a']), isTrue);
      await store.ensure(['a']);
      expect(reads, 2);
    },
  );
  test(
    'a suspended page clears the batch (wall clock ran ahead of monotonic)',
    () async {
      final r = Rig();
      await r.store.ensure(['a']);
      r.now += 1000;
      r.wall += 1000;
      expect(r.store.codeFor('a'), isNotNull);
      r.now += 1000; // monotonic paused during sleep
      r.wall += 120000;
      expect(r.store.codeFor('a'), isNull);
      expect(r.store.hasBatch, isFalse);
      // The device clock being wrong is not a suspend: only deltas count.
      final w = Rig();
      await w.store.ensure(['a']);
      w.wall -= 3600000;
      w.now += 1000;
      expect(w.store.codeFor('a'), isNotNull);
      w.wall += 1000;
      w.now += 1000;
      expect(w.store.codeFor('a'), isNotNull);
    },
  );

  test('repeated failures back off exponentially with jitter', () async {
    final r = Rig();
    var fetches = 0;
    r.respond = (_) async {
      fetches++;
      return SessionResponse(500, '{}');
    };
    await r.store.ensure(['a']);
    expect(fetches, 1);
    final waits = <int>[];
    for (var i = 0; i < 7; i++) {
      var waited = 0;
      final n = fetches;
      while (fetches == n) {
        r.now += 1000;
        r.wall += 1000;
        waited += 1000;
        await r.store.ensure(['a']);
        if (waited > 400000) fail('never retried');
      }
      waits.add(waited);
    }
    expect(waits.first, inInclusiveRange(5000, 9000));
    expect(waits[2], greaterThan(waits[0]));
    expect(waits[4], greaterThan(waits[2]));
    expect(waits.last, lessThanOrEqualTo(185000));
    r.respond = (_) async => SessionResponse(200, body());
    r.now += 200000;
    r.wall += 200000;
    await r.store.ensure(['a']);
    expect(r.store.codeFor('a'), isNotNull);
  });

  test('retain prunes the request set and held codes to the catalog', () async {
    final r = Rig();
    await r.store.ensure(['a', 'b']);
    r.store.retain({'a'});
    expect(r.store.codeFor('b'), isNull);
    r.now += 545000;
    await r.store.ensure(['a']);
    expect(r.calls.last, ['a']);
  });

  test(
    'clear then a new request: the old one finishing never drops the new one',
    () async {
      final r = Rig();
      final first = Completer<SessionResponse>(),
          second = Completer<SessionResponse>();
      var n = 0;
      r.respond = (_) => (n++ == 0 ? first : second).future;
      final f1 = r.store.ensure(['a']);
      await Future<void>.delayed(Duration.zero);
      r.store.clear();
      final f2 = r.store.ensure(['a']);
      await Future<void>.delayed(Duration.zero);
      first.complete(SessionResponse(200, body()));
      await f1;
      r.store.ensure(['a']);
      expect(r.calls.length, 2, reason: 'still the one in flight');
      second.complete(SessionResponse(200, body()));
      await f2;
      expect(r.store.codeFor('a'), isNotNull);
    },
  );

  test('one request serves several entries and codes tick by period', () async {
    final r = Rig();
    r.respond = (_) async => SessionResponse(
      200,
      body(
        entries: [
          for (final id in ['a', 'b'])
            {
              'entryId': id,
              'period': 30,
              'digits': 6,
              'validFrom': (serverStart ~/ 1000) ~/ 30 * 30,
              'codes': ['111111', '222222', '333333'],
            },
        ],
      ),
    );
    await r.store.ensure(['a', 'b']);
    expect(r.calls, [
      ['a', 'b'],
    ]);
    final c = r.store.codeFor('a')!;
    expect(c.value, '111111');
    expect(c.secondsLeft, 20);
    r.now += 20000;
    expect(r.store.codeFor('b')!.value, '222222');
    r.now += 30000;
    expect(r.store.codeFor('a')!.value, '333333');
    r.now += 30000;
    expect(r.store.codeFor('a'), isNull); // past the delivered codes
  });

  test(
    'device clock is irrelevant, only serverNow plus elapsed time',
    () async {
      final r = Rig()..now = 987654321;
      await r.store.ensure(['a']);
      expect(r.store.codeFor('a')!.value, '100000');
      r.now += 25000;
      expect(r.store.codeFor('a')!.value, '100001');
    },
  );

  test('hard expiry is the granted window, not the last interval', () async {
    final r = Rig();
    r.respond = (_) async => SessionResponse(
      200,
      body(
        window: 60,
        entries: [
          {
            'entryId': 'a',
            'period': 30,
            'digits': 6,
            'validFrom': (serverStart ~/ 1000) ~/ 30 * 30,
            'codes': ['111111', '222222', '333333'],
          },
        ],
      ),
    );
    await r.store.ensure(['a']);
    r.now += 59000;
    expect(r.store.codeFor('a')!.value, '333333');
    r.now += 2000;
    expect(r.store.codeFor('a'), isNull);
    expect(r.store.hasBatch, isFalse);
  });

  test('never outlives the session', () async {
    final r = Rig()..session = 45000;
    await r.store.ensure(['a']);
    r.now += 40000;
    expect(r.store.codeFor('a'), isNotNull);
    r.now += 6000;
    expect(r.store.codeFor('a'), isNull);
    final gone = Rig()..session = 0;
    await expectLater(gone.store.ensure(['a']), throwsA(isA<ClientFailure>()));
    expect(gone.store.hasBatch, isFalse);
  });

  test('a single-entry caller keeps the entries the list asked for', () async {
    final r = Rig();
    await r.store.ensure(['a', 'b']);
    r.now += 545000;
    await r.store.ensure(['c']);
    expect(r.calls.last.toSet(), {'a', 'b', 'c'});
  });

  test(
    'refresh is wanted 60 s before expiry and no request before that',
    () async {
      final r = Rig();
      await r.store.ensure(['a']);
      expect(r.store.needsFetch(['a']), isFalse);
      r.now += 100000;
      await r.store.ensure(['a']);
      expect(r.calls.length, 1);
      r.now += 450000;
      expect(r.store.needsFetch(['a']), isTrue);
      await r.store.ensure(['a']);
      expect(r.calls.length, 2);
    },
  );

  test(
    'a new entry triggers one fetch, an omitted one does not loop',
    () async {
      final r = Rig();
      r.respond = (ids) async => SessionResponse(
        200,
        body(
          entries: [
            {
              'entryId': 'a',
              'period': 30,
              'digits': 6,
              'validFrom': (serverStart ~/ 1000) ~/ 30 * 30,
              'codes': ['111111'],
            },
          ],
          omitted: [
            if (ids.contains('fast'))
              {'entryId': 'fast', 'reason': 'period_too_short'},
          ],
        ),
      );
      await r.store.ensure(['a', 'fast']);
      expect(r.store.omitted('fast'), isTrue);
      expect(r.store.codeFor('fast'), isNull);
      await r.store.ensure(['a', 'fast']);
      expect(r.calls.length, 1);
      r.respond = (_) async => SessionResponse(200, body());
      await r.store.ensure(['a', 'b']);
      expect(r.calls.length, 2);
    },
  );

  test('rate limit keeps the usable batch and backs off', () async {
    final r = Rig();
    await r.store.ensure(['a']);
    r.now += 545000;
    r.respond = (_) async => SessionResponse(429, '{}');
    await r.store.ensure(['a']);
    expect(r.calls.length, 2);
    expect(r.store.codeFor('a'), isNotNull);
    await r.store.ensure(['a']);
    expect(r.calls.length, 2, reason: 'backing off');
    r.now += 50000;
    r.respond = (_) async => SessionResponse(200, body());
    await r.store.ensure(['a']);
    expect(r.calls.length, 3);
  });

  test('401 and 403 clear everything at once', () async {
    for (final status in [401, 403]) {
      final r = Rig();
      await r.store.ensure(['a']);
      await Future<void>.delayed(Duration.zero);
      r.now += 545000;
      r.respond = (_) async => SessionResponse(status, '{}');
      // The held code still answers the caller; the refresh runs behind it.
      await r.store.ensure(['a']).then((_) {}, onError: (_) {});
      await Future<void>.delayed(Duration.zero);
      expect(r.store.codeFor('a'), isNull);
      expect(r.store.hasBatch, isFalse);
    }
  });

  test(
    'clear drops the batch and a response arriving later is ignored',
    () async {
      final r = Rig();
      await r.store.ensure(['a']);
      r.store.clear();
      expect(r.store.codeFor('a'), isNull);
      final gate = Completer<SessionResponse>();
      r.respond = (_) => gate.future;
      final f = r.store.ensure(['a']);
      r.store.clear();
      gate.complete(SessionResponse(200, body()));
      await f;
      expect(r.store.codeFor('a'), isNull);
    },
  );

  test('concurrent callers share one request', () async {
    final r = Rig();
    final gate = Completer<SessionResponse>();
    r.respond = (_) => gate.future;
    final f = [
      r.store.ensure(['a']),
      r.store.ensure(['a']),
    ];
    gate.complete(SessionResponse(200, body()));
    await Future.wait(f);
    expect(r.calls.length, 1);
  });

  test('ids longer than the server accepts are never requested', () async {
    final r = Rig();
    await r.store.ensure(['a', 'x' * 65]);
    expect(r.calls.single, ['a']);
  });

  test('a late response does not renew the window', () async {
    final r = Rig();
    final gate = Completer<SessionResponse>();
    r.respond = (_) => gate.future;
    final f = r.store.ensure(['a']);
    await Future<void>.delayed(Duration.zero);
    r.now += 8000; // slow request: generation started ~8 s before receipt
    gate.complete(SessionResponse(200, body()));
    await f;
    r.now += 590000;
    expect(r.store.codeFor('a'), isNotNull);
    r.now += 5000;
    expect(
      r.store.codeFor('a'),
      isNull,
      reason: 'expiry is 600 s from generation, not from receipt',
    );
  });

  /// A server double for chunk tests: serves exactly the ids asked, one code
  /// per period, and records each request.
  String servedFor(List<String> ids, {List<String> omit = const []}) => body(
    entries: [
      for (final id in ids.where((i) => !omit.contains(i)))
        {
          'entryId': id,
          'period': 30,
          'digits': 6,
          'validFrom': (serverStart ~/ 1000) ~/ 30 * 30,
          'codes': [for (var i = 0; i < 21; i++) '${200000 + i}'],
        },
    ],
    omitted: [
      for (final id in ids.where(omit.contains))
        {'entryId': id, 'reason': 'unavailable'},
    ],
  );

  List<String> ids(int n) => [for (var i = 0; i < n; i++) 'e$i'];

  test('20 entries load as 4 sequential requests of at most 5', () async {
    final r = Rig();
    var running = 0, peak = 0;
    r.respond = (asked) async {
      running++;
      peak = running > peak ? running : peak;
      await Future<void>.delayed(Duration.zero);
      running--;
      return SessionResponse(200, servedFor(asked));
    };
    final all = ids(20);
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 4);
    expect(r.calls.every((c) => c.length <= 5), isTrue);
    expect(peak, 1, reason: 'never parallel');
    expect(r.calls.expand((c) => c).toSet(), all.toSet());
    for (final id in all) {
      expect(r.store.codeFor(id), isNotNull, reason: id);
    }
  });

  test(
    'beyond 20 entries are never requested; the rest wait on demand',
    () async {
      final r = Rig();
      r.respond = (asked) async => SessionResponse(200, servedFor(asked));
      await r.store.ensure(ids(30));
      await Future<void>.delayed(Duration.zero);
      final asked = r.calls.expand((c) => c).toList();
      expect(asked.length, 20);
      expect(asked.contains('e25'), isFalse);
      expect(r.store.codeFor('e25'), isNull);
      expect(r.store.omitted('e25'), isFalse);
    },
  );

  test(
    'a caller waiting on one entry is answered before the chain ends',
    () async {
      final r = Rig();
      final gate = Completer<void>();
      var n = 0;
      r.respond = (asked) async {
        if (n++ == 1) await gate.future;
        return SessionResponse(200, servedFor(asked));
      };
      final all = ids(10);
      await r.store.ensure(['e0']);
      final chain = r.store.ensure(all.sublist(0, 6));
      gate.complete();
      await chain;
      expect(r.store.codeFor('e0'), isNotNull);
    },
  );

  test('a 429 stops the chain and backs off, with no retry loop', () async {
    final r = Rig();
    var n = 0;
    r.respond = (asked) async {
      n++;
      return n == 2
          ? SessionResponse(429, '{}')
          : SessionResponse(200, servedFor(asked));
    };
    final all = ids(20);
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 2, reason: 'stopped at the limited request');
    expect(r.store.codeFor('e0'), isNotNull);
    expect(r.store.codeFor('e10'), isNull);
    for (var i = 0; i < 20; i++) {
      r.now += 1000;
      r.wall += 1000;
      await r.store.ensure(all);
    }
    expect(r.calls.length, 2, reason: 'quiet during the 30 s minimum back-off');
    r.now += 60000;
    r.wall += 60000;
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.store.codeFor('e10'), isNotNull);
    expect(r.calls.length, lessThanOrEqualTo(2 + 4));
  });

  test('a failing group does not starve the others', () async {
    final r = Rig();
    r.respond = (asked) async => asked.contains('e0')
        ? SessionResponse(500, '{}')
        : SessionResponse(200, servedFor(asked));
    final all = ids(15);
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.store.codeFor('e0'), isNull);
    expect(r.store.codeFor('e7'), isNotNull);
    expect(r.store.codeFor('e14'), isNotNull);
    final before = r.calls.length;
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(
      r.calls.length,
      before,
      reason: 'failed entries wait out their own back-off',
    );
  });

  test('an entry the server leaves out does not loop', () async {
    final r = Rig();
    r.respond = (asked) async =>
        SessionResponse(200, servedFor(asked.where((i) => i != 'e1').toList()));
    await r.store.ensure(ids(3));
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 1);
    await r.store.ensure(ids(3));
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 1);
  });

  test('chunks refresh on their own expiry, only what is due', () async {
    final r = Rig();
    r.respond = (asked) async => SessionResponse(200, servedFor(asked));
    final all = ids(10);
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 2);
    r.now += 100000;
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 2, reason: 'nothing due yet');
    r.now += 450000;
    r.wall += 450000;
    await r.store.ensure(all);
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 4);
    expect(r.calls.skip(2).every((c) => c.length <= 5), isTrue);
  });

  test('clear mid-chain drops the chain: nothing late is stored', () async {
    final r = Rig();
    final gate = Completer<SessionResponse>();
    var n = 0;
    r.respond = (asked) => n++ == 0
        ? Future.value(SessionResponse(200, servedFor(asked)))
        : gate.future;
    final f = r.store.ensure(ids(10));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    r.store.clear();
    gate.complete(SessionResponse(200, servedFor(ids(10).sublist(5))));
    await f;
    await Future<void>.delayed(Duration.zero);
    expect(r.store.hasBatch, isFalse);
    expect(r.store.codeFor('e7'), isNull);
    expect(r.calls.length, 2, reason: 'no third request after the clear');
  });

  test('concurrent callers share one chain', () async {
    final r = Rig();
    r.respond = (asked) async => SessionResponse(200, servedFor(asked));
    final all = ids(10);
    await Future.wait([r.store.ensure(all), r.store.ensure(all)]);
    await Future<void>.delayed(Duration.zero);
    expect(r.calls.length, 2);
  });

  test('malformed or unsafe responses are discarded whole', () async {
    final good = jsonDecode(body()) as Map<String, dynamic>;
    Map<String, dynamic> copy() => jsonDecode(body()) as Map<String, dynamic>;
    Map<String, dynamic> entry(Map<String, dynamic> m) =>
        (m['entries'] as List).first as Map<String, dynamic>;
    final bad = <String, String>{};
    void add(String n, void Function(Map<String, dynamic>) f) {
      final m = copy();
      f(m);
      bad[n] = jsonEncode(m);
    }

    add('extra key', (m) => m['x'] = 1);
    add('no expiry', (m) => m.remove('windowExpiresAt'));
    add('expiry in the past', (m) => m['windowExpiresAt'] = serverStart);
    add('generation start in the future', (m) {
      m['windowExpiresAt'] = serverStart + 602000;
    });
    add('generation start long ago', (m) {
      m['windowExpiresAt'] = serverStart + 600000 - 11000;
    });
    add('expiry not whole seconds', (m) => m['windowExpiresAt'] += 500);
    add('too many codes for the period', (m) {
      entry(m)['period'] = 60;
      entry(m)['validFrom'] = serverStart ~/ 1000 ~/ 60 * 60;
      entry(m)['codes'] = [for (var i = 0; i < 12; i++) '123456'];
    });
    add('window 601', (m) => m['windowSeconds'] = 601);
    add('window 0', (m) => m['windowSeconds'] = 0);
    add('unrequested entry', (m) => entry(m)['entryId'] = 'zzz');
    add('extra entry key', (m) => entry(m)['seed'] = 'x');
    add('letters in code', (m) => entry(m)['codes'] = ['12345a']);
    add('wrong length', (m) => entry(m)['codes'] = ['12345']);
    add('digits mismatch', (m) => entry(m)['digits'] = 8);
    add('period 0', (m) => entry(m)['period'] = 0);
    add('unaligned', (m) => entry(m)['validFrom'] = entry(m)['validFrom'] + 1);
    add('first code not current', (m) {
      entry(m)['validFrom'] = entry(m)['validFrom'] + 30;
    });
    add('expired first code', (m) {
      entry(m)['validFrom'] = entry(m)['validFrom'] - 30;
    });
    add('32 codes', (m) {
      entry(m)['codes'] = [for (var i = 0; i < 32; i++) '123456'];
    });
    add('no codes', (m) => entry(m)['codes'] = []);
    add('duplicate', (m) => (m['entries'] as List).add(entry(m)));
    add(
      'bad omitted reason',
      (m) => m['omitted'] = [
        {'entryId': 'a', 'reason': 'x'},
      ],
    );
    add(
      'omitted and present',
      (m) => m['omitted'] = [
        {'entryId': 'a', 'reason': 'unavailable'},
      ],
    );
    add('not json', (m) {});
    bad['not json'] = 'nope';
    bad['array'] = '[]';
    expect(good['windowSeconds'], 600);
    for (final e in bad.entries) {
      final r = Rig();
      r.respond = (_) async => SessionResponse(200, e.value);
      await r.store.ensure(['a']);
      expect(r.store.hasBatch, isFalse, reason: e.key);
      expect(r.store.codeFor('a'), isNull, reason: e.key);
    }
    final big = Rig();
    big.respond = (_) async => SessionResponse(200, ' ' * 16385 + body());
    await big.store.ensure(['a']);
    expect(big.store.hasBatch, isFalse);
  });

  test('a bad refresh never replaces a still-valid batch', () async {
    final r = Rig();
    await r.store.ensure(['a']);
    r.now += 545000;
    r.respond = (_) async => SessionResponse(200, 'nope');
    await r.store.ensure(['a']);
    expect(r.store.codeFor('a'), isNotNull);
  });

  test('the monotonic clock going backwards clears the batch', () async {
    final r = Rig();
    await r.store.ensure(['a']);
    r.now -= 1;
    expect(r.store.codeFor('a'), isNull);
    expect(r.store.hasBatch, isFalse);
  });

  test('no secret material in toString', () {
    expect(
      const BatchCode('a', '123456', 1, 30).toString(),
      isNot(contains('123456')),
    );
  });

  for (final status in [404, 501]) {
    test(
      'a $status batch route stops batching: no retry loop, kept across clear',
      () async {
        var calls = 0, now = 1000;
        final store = TotpBatchStore(
          fetch: (_) async {
            calls++;
            return SessionResponse(status, '{}');
          },
          monotonicMilliseconds: () => now,
          wallMilliseconds: () => now,
          sessionExpiresAt: () async => serverStart + 3600000,
        );
        await store.ensure(['a']);
        expect(calls, 1);
        expect(store.unavailable, isTrue);
        expect(store.needsFetch(['a']), isFalse);
        for (var i = 0; i < 5; i++) {
          now += 200000;
          await store.ensure(['a', 'b']);
        }
        store.clear();
        await store.ensure(['a']);
        expect(calls, 1);
        expect(store.codeFor('a'), isNull);
      },
    );
  }
}
