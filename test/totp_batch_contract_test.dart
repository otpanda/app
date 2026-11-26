import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/totp_batch_contract.dart';

// Test policy values only. They are not product defaults.
const policy = BatchPolicy(
  maxEntries: 10,
  maxTotalCodes: 64,
  minPeriodSeconds: 20,
  maxPeriodSeconds: 86400,
  maxWindowSeconds: 600,
  minRemainingMs: 1000,
);

const serverNow = 1795614901410; // ms
int get nowSec => serverNow ~/ 1000;

String code(String id, int i, int digits) {
  var mod = 1;
  for (var k = 0; k < digits; k++) {
    mod *= 10;
  }
  return ((id.hashCode.abs() + i * 7919) % mod).toString().padLeft(digits, '0');
}

/// Builds a body the way the server does: head aligned to the period, window
/// seconds of coverage.
Map<String, dynamic> body(
  Map<String, (int period, int digits)> ids, {
  int now = serverNow,
  int window = 60,
  List<Map<String, dynamic>> omitted = const [],
}) {
  final h = now ~/ 1000 + window;
  var total = 0;
  final entries = <Map<String, dynamic>>[];
  ids.forEach((id, pd) {
    final p = pd.$1, start = (now ~/ 1000 ~/ p) * p;
    final n = ((h - start - 1) ~/ p) + 1;
    total += n;
    entries.add({
      'entryId': id,
      'period': p,
      'digits': pd.$2,
      'validFrom': start,
      'codes': [for (var i = 0; i < n; i++) code(id, i, pd.$2)],
    });
  });
  return {
    'serverNow': now,
    'coverageUntil': entries.isEmpty ? null : h * 1000,
    'totalCodes': total,
    'entries': entries,
    'omitted': omitted,
  };
}

Matcher bad() => throwsFormatException;

CommonHorizonBatch parse(Object? b, Set<String> ids) =>
    CommonHorizonBatch.parse(b, requestedIds: ids, policy: policy);

void main() {
  group('parser', () {
    test('accepts 6, 7 and 8 digit entries with different periods', () {
      final b = parse(body({'a': (30, 6), 'b': (60, 7), 'c': (20, 8)}), {
        'a',
        'b',
        'c',
      });
      expect(b.entries.map((e) => e.digits), [6, 7, 8]);
      expect(b.entries[1].period, 60);
      expect(b.coverageUntil, (nowSec + 60) * 1000);
    });

    test(
      'omitted entries with both reasons are accepted and counted as present',
      () {
        final raw = body(
          {'a': (30, 6)},
          omitted: [
            {'entryId': 'b', 'reason': 'period_too_short'},
            {'entryId': 'c', 'reason': 'unavailable'},
          ],
        );
        final b = parse(raw, {'a', 'b', 'c'});
        expect(b.omitted.map((o) => (o.entryId, o.periodTooShort)), [
          ('b', true),
          ('c', false),
        ]);
      },
    );

    test('all omitted: no entries, coverage must be null and total 0', () {
      final ok = {
        'serverNow': serverNow,
        'coverageUntil': null,
        'totalCodes': 0,
        'entries': [],
        'omitted': [
          {'entryId': 'a', 'reason': 'unavailable'},
        ],
      };
      expect(parse(ok, {'a'}).entries, isEmpty);
      expect(
        () => parse({...ok, 'coverageUntil': serverNow + 5000}, {'a'}),
        bad(),
      );
    });

    test('exact key sets', () {
      final good = body({'a': (30, 6)});
      expect(() => parse({...good, 'extra': 1}, {'a'}), bad());
      expect(() => parse({...good}..remove('totalCodes'), {'a'}), bad());
      expect(() => parse([good], {'a'}), bad());
      expect(() => parse(null, {'a'}), bad());
      final e = (good['entries'] as List).first as Map<String, dynamic>;
      expect(
        () => parse(
          {
            ...good,
            'entries': [
              {...e, 'x': 1},
            ],
          },
          {'a'},
        ),
        bad(),
      );
      expect(
        () => parse(
          {
            ...good,
            'entries': [
              {...e}..remove('digits'),
            ],
          },
          {'a'},
        ),
        bad(),
      );
      expect(
        () => parse(
          {
            ...good,
            'omitted': [
              {'entryId': 'z'},
            ],
          },
          {'a'},
        ),
        bad(),
      );
    });

    test('membership: unknown, duplicate, missing, entry also omitted', () {
      final two = body({'a': (30, 6), 'b': (30, 6)});
      expect(() => parse(two, {'a'}), bad(), reason: 'unrequested b');
      expect(() => parse(two, {'a', 'b', 'c'}), bad(), reason: 'c missing');
      final dup = body({'a': (30, 6)});
      final e = (dup['entries'] as List).first;
      expect(
        () => parse(
          {
            ...dup,
            'entries': [e, e],
          },
          {'a', 'b'},
        ),
        bad(),
      );
      final both = body(
        {'a': (30, 6)},
        omitted: [
          {'entryId': 'a', 'reason': 'unavailable'},
        ],
      );
      expect(() => parse(both, {'a', 'b'}), bad());
      expect(
        () => parse(body({'a': (30, 6)}), {}),
        bad(),
        reason: 'no request',
      );
    });

    test('code shape: padding, length for digits, non digits, types', () {
      Map<String, dynamic> withCodes(List<dynamic> codes, {int digits = 6}) {
        final b = body({'a': (30, digits)});
        final e = Map<String, dynamic>.from(
          (b['entries'] as List).first as Map,
        );
        e['codes'] = codes;
        return {
          ...b,
          'entries': [e],
          'totalCodes': codes.length,
        };
      }

      Map<String, dynamic> fix(Map<String, dynamic> b) {
        final e = (b['entries'] as List).first as Map;
        final n = (e['codes'] as List).length;
        final start = e['validFrom'] as int;
        return {
          ...b,
          'coverageUntil': (start + n * 30) * 1000 > serverNow + 1000
              ? (start + n * 30) * 1000
              : b['coverageUntil'],
        };
      }

      final n =
          ((body({'a': (30, 6)})['entries'] as List).first['codes'] as List)
              .length;
      List<String> ok(int digits) => List.filled(n, '0' * digits);
      parse(withCodes(ok(6)), {'a'});
      parse(withCodes(ok(7), digits: 7), {'a'});
      parse(withCodes(ok(8), digits: 8), {'a'});
      expect(
        () => parse(withCodes([...ok(6)]..[0] = '12345'), {'a'}),
        bad(),
        reason: 'unpadded',
      );
      expect(
        () => parse(withCodes(ok(6), digits: 7), {'a'}),
        bad(),
        reason: '6 chars for 7 digits',
      );
      expect(
        () => parse(withCodes(ok(7), digits: 6), {'a'}),
        bad(),
        reason: '7 chars for 6 digits',
      );
      expect(() => parse(withCodes([...ok(6)]..[0] = '12a456'), {'a'}), bad());
      expect(() => parse(withCodes([...ok(6)]..[0] = ' 12345'), {'a'}), bad());
      expect(
        () => parse(withCodes([...ok(6)]..[0] = '１２３４５６'), {'a'}),
        bad(),
        reason: 'non-ascii digits',
      );
      expect(() => parse(withCodes([...ok(6)]..[0] = 123456), {'a'}), bad());
      expect(() => parse(withCodes(<String>[]), {'a'}), bad());
      expect(fix, isNotNull);
    });

    test('digits other than 6, 7, 8 and non-int digits are refused', () {
      for (final d in [5, 9, 0, -1, '6', 6.0]) {
        final b = body({'a': (30, 6)});
        final e = Map<String, dynamic>.from((b['entries'] as List).first as Map)
          ..['digits'] = d;
        expect(
          () => parse(
            {
              ...b,
              'entries': [e],
            },
            {'a'},
          ),
          bad(),
          reason: '$d',
        );
      }
    });

    test('period bounds and alignment', () {
      Map<String, dynamic> mut(String k, Object? v) {
        final b = body({'a': (30, 6)});
        final e = Map<String, dynamic>.from((b['entries'] as List).first as Map)
          ..[k] = v;
        return {
          ...b,
          'entries': [e],
        };
      }

      expect(() => parse(mut('period', 19), {'a'}), bad());
      expect(() => parse(mut('period', 0), {'a'}), bad());
      expect(() => parse(mut('period', 86401), {'a'}), bad());
      expect(() => parse(mut('period', '30'), {'a'}), bad());
      expect(
        () => parse(mut('validFrom', ((nowSec ~/ 30) * 30) + 1), {'a'}),
        bad(),
        reason: 'misaligned',
      );
    });

    test('first code must be valid at serverNow', () {
      Map<String, dynamic> shift(int by) {
        final b = body({'a': (30, 6)});
        final e = Map<String, dynamic>.from(
          (b['entries'] as List).first as Map,
        );
        e['validFrom'] = (e['validFrom'] as int) + by;
        return {
          ...b,
          'entries': [e],
        };
      }

      expect(
        () => parse(shift(30), {'a'}),
        bad(),
        reason: 'starts in the future',
      );
      expect(
        () => parse(shift(-30), {'a'}),
        bad(),
        reason: 'head already expired',
      );
    });

    test('totals, coverage and window checks', () {
      final good = body({'a': (30, 6), 'b': (60, 6)});
      expect(
        () => parse(
          {...good, 'totalCodes': (good['totalCodes'] as int) + 1},
          {'a', 'b'},
        ),
        bad(),
      );
      expect(
        () => parse(
          {...good, 'coverageUntil': (nowSec + 400) * 1000},
          {'a', 'b'},
        ),
        bad(),
        reason: 'entries end before coverage',
      );
      expect(
        () => parse({...good, 'coverageUntil': serverNow + 500}, {'a', 'b'}),
        bad(),
        reason: 'under minRemaining',
      );
      expect(
        () => parse(body({'a': (30, 6)}, window: 601), {'a'}),
        bad(),
        reason: 'over max window',
      );
      expect(() => parse({...good, 'coverageUntil': null}, {'a', 'b'}), bad());
      const tiny = BatchPolicy(
        maxEntries: 10,
        maxTotalCodes: 3,
        minPeriodSeconds: 20,
        maxPeriodSeconds: 86400,
        maxWindowSeconds: 600,
        minRemainingMs: 1000,
      );
      expect(
        () => CommonHorizonBatch.parse(
          good,
          requestedIds: {'a', 'b'},
          policy: tiny,
        ),
        bad(),
        reason: 'budget',
      );
    });

    test('safe integer bounds', () {
      final good = body({'a': (30, 6)});
      for (final v in [-1, 9007199254740992, 1.5, '1', null]) {
        expect(
          () => parse({...good, 'serverNow': v}, {'a'}),
          bad(),
          reason: '$v',
        );
      }
      expect(() => parse({...good, 'totalCodes': -1}, {'a'}), bad());
      expect(
        () => parse({...good, 'coverageUntil': 9007199254740992}, {'a'}),
        bad(),
      );
      final e = Map<String, dynamic>.from(
        (good['entries'] as List).first as Map,
      )..['validFrom'] = 9007199254740991 ~/ 30 * 30;
      expect(
        () => parse(
          {
            ...good,
            'entries': [e],
          },
          {'a'},
        ),
        bad(),
      );
    });

    test('invalid policy and entry ids', () {
      final good = body({'a': (30, 6)});
      const badPolicy = BatchPolicy(
        maxEntries: 10,
        maxTotalCodes: 64,
        minPeriodSeconds: 0,
        maxPeriodSeconds: 10,
        maxWindowSeconds: 600,
        minRemainingMs: 1000,
      );
      expect(
        () => CommonHorizonBatch.parse(
          good,
          requestedIds: {'a'},
          policy: badPolicy,
        ),
        bad(),
      );
      expect(() => parse(good, {'a b'}), bad());
      expect(() => parse(good, {''}), bad());
    });

    test('toString never shows codes', () {
      final b = parse(body({'a': (30, 6)}), {'a'});
      expect(
        b.entries.first.toString(),
        isNot(contains(b.entries.first.codes.first)),
      );
    });
  });

  group('store', () {
    late int tick;
    late BatchCodeStore store;
    setUp(() {
      tick = 5000;
      store = BatchCodeStore(monotonicMilliseconds: () => tick);
    });

    BatchRequest begin(Set<String> ids) => store.begin(ids);

    test(
      'zero latency: shows the exact code and switches at the period boundary',
      () {
        final r = begin({'a'});
        expect(store.accept(r, body({'a': (30, 6)}), policy: policy), isTrue);
        final start = (nowSec ~/ 30) * 30;
        final idx = (nowSec - start) ~/ 30;
        expect(idx, 0);
        expect(store.current('a')!.value, code('a', 0, 6));
        // advance to just after the next boundary
        tick += (start + 30) * 1000 - serverNow + 1;
        expect(store.current('a')!.value, code('a', 1, 6));
        expect(store.current('a')!.remainingMs, 29999);
        expect(store.current('zzz'), isNull);
      },
    );

    test('uncertain network time hides the code near a boundary instead of guessing', () {
      tick = 5000;
      final r = begin({'a'});
      tick = 5400; // 400 ms round trip
      store.accept(r, body({'a': (30, 6)}), policy: policy);
      final start = (nowSec ~/ 30) * 30;
      final boundary = (start + 30) * 1000;
      // true boundary in ticks lies between these two
      final tLow = 5400 + (boundary - serverNow); // if stamped at arrival
      final tHigh = 5000 + (boundary - serverNow); // if stamped at send
      tick = tHigh - 1;
      expect(store.awaitingBoundary('a'), false);
      expect(store.current('a')!.value, code('a', 0, 6));
      tick = tHigh + 1;
      expect(store.awaitingBoundary('a'), true);
      expect(store.awaitingBoundary('missing'), false);
      expect(
        store.current('a'),
        isNull,
        reason: 'could already be the next code',
      );
      tick = tLow - 1;
      expect(store.current('a'), isNull, reason: 'still ambiguous');
      tick = tLow;
      expect(store.awaitingBoundary('a'), false);
      expect(store.current('a')!.value, code('a', 1, 6));
    });

    test(
      'renewing status agrees with strict validity across RTT intervals',
      () {
        for (final latency in [1, 20, 400, 1500]) {
          for (final period in [20, 30, 60, 300]) {
            tick = 5000;
            final subject = BatchCodeStore(monotonicMilliseconds: () => tick);
            final r = subject.begin({'a'});
            tick += latency;
            subject.accept(r, body({'a': (period, 6)}), policy: policy);
            final start = (nowSec ~/ period) * period;
            final boundary = (start + period) * 1000;
            final at = 5000 + boundary - serverNow;
            for (final delta in [
              -1,
              0,
              1,
              latency ~/ 2,
              latency - 1,
              latency,
              latency + 1,
            ]) {
              final next = at + delta;
              if (next < tick) continue;
              tick = next;
              final renewing = subject.awaitingBoundary('a');
              final value = subject.current('a');
              if (renewing) expect(value, isNull);
              if (subject.hasCoverage('a') && value == null) {
                expect(renewing, isTrue);
              }
            }
            subject.clear();
            expect(subject.awaitingBoundary('a'), isFalse);
          }
        }
      },
    );

    test('hasNextCode is true only when a later code is held', () {
      final r = begin({'a'});
      store.accept(r, body({'a': (30, 6)}, window: 2), policy: policy);
      expect(store.hasNextCode('a'), isFalse, reason: 'current-only');
      expect(store.hasNextCode('zzz'), isFalse);
      store.clear();
      final r2 = begin({'a'});
      store.accept(r2, body({'a': (30, 6)}), policy: policy);
      expect(store.hasNextCode('a'), isTrue);
    });

    test('a code never shows before it can be valid and never after it may have ended', () {
      final r = begin({'a'});
      tick = 5400;
      store.accept(r, body({'a': (30, 6)}), policy: policy);
      final end = ((nowSec ~/ 30) * 30 + 30) * 1000;
      // last tick where even the latest clock is inside code 0
      tick = 5000 + (end - serverNow) - 1;
      expect(store.current('a')!.remainingMs, 1);
      tick += 1;
      expect(store.current('a'), isNull);
    });

    test('available lists only currently valid entries', () {
      final r = begin({'a', 'b'});
      store.accept(r, body({'a': (30, 6), 'b': (60, 8)}), policy: policy);
      expect(store.available()..sort(), ['a', 'b']);
      tick += 10 * 60 * 1000;
      expect(store.available(), isEmpty);
    });

    test('clear cancels in-flight requests: a late response is dropped', () {
      final r = begin({'a'});
      store.clear();
      expect(store.accept(r, body({'a': (30, 6)}), policy: policy), isFalse);
      expect(store.current('a'), isNull);
    });

    test(
      'out-of-order responses: an older request cannot replace a newer one',
      () {
        final r1 = begin({'a'});
        final r2 = begin({'a'});
        expect(store.accept(r2, body({'a': (30, 6)}), policy: policy), isTrue);
        final v = store.current('a')!.value;
        expect(store.accept(r1, body({'a': (20, 6)}), policy: policy), isFalse);
        expect(store.current('a')!.value, v);
        expect(
          store.accept(r2, body({'a': (30, 6)}), policy: policy),
          isFalse,
          reason: 'replay of the same token',
        );
      },
    );

    test('an invalid response clears everything and throws', () {
      store.accept(begin({'a'}), body({'a': (30, 6)}), policy: policy);
      expect(store.current('a'), isNotNull);
      final r = begin({'a'});
      final badBody = {
        ...body({'a': (30, 6)}),
        'extra': 1,
      };
      expect(
        () => store.accept(r, badBody, policy: policy),
        throwsFormatException,
      );
      expect(store.current('a'), isNull);
      expect(store.available(), isEmpty);
      expect(store.coverageRemainingMs(), 0);
    });

    test('a refresh replaces requested entries, keeps other still-valid entries, drops omitted ones', () {
      store.accept(
        begin({'a', 'b', 'c'}),
        body({'a': (30, 6), 'b': (30, 6), 'c': (30, 6)}),
        policy: policy,
      );
      final keepB = store.current('b')!.value;
      store.accept(
        begin({'a', 'c'}),
        body(
          {'a': (30, 6)},
          omitted: [
            {'entryId': 'c', 'reason': 'unavailable'},
          ],
        ),
        policy: policy,
      );
      expect(store.current('a'), isNotNull);
      expect(store.current('c'), isNull, reason: 'omitted is removed');
      expect(
        store.current('b')!.value,
        keepB,
        reason: 'not part of this request',
      );
    });

    test('a refresh during the old coverage keeps showing without a gap', () {
      store.accept(begin({'a'}), body({'a': (30, 6)}), policy: policy);
      tick += 40000;
      final later = serverNow + 40000;
      store.accept(
        begin({'a'}),
        body({'a': (30, 6)}, now: later),
        policy: policy,
      );
      expect(store.current('a'), isNotNull);
    });

    test('a response that already expired on arrival is refused', () {
      final r = begin({'a'});
      tick += 70000; // longer than the 60 s coverage
      expect(
        () => store.accept(r, body({'a': (30, 6)}), policy: policy),
        throwsFormatException,
      );
      expect(store.available(), isEmpty);
    });

    test('clock below the recorded high-water throws on begin and keeps the store empty', () {
      store.accept(begin({'a'}), body({'a': (30, 6)}), policy: policy);
      tick -= 1;
      expect(() => begin({'a'}), throwsFormatException);
      tick += 1;
      expect(store.current('a'), isNull);
    });

    test('invalid ids and an invalid clock value are refused', () {
      expect(() => begin({}), throwsFormatException);
      expect(() => begin({'a b'}), throwsFormatException);
      final s = BatchCodeStore(monotonicMilliseconds: () => -1);
      expect(() => s.begin({'a'}), throwsFormatException);
    });

    test('needsRefresh uses the caller lead; no coverage means refresh', () {
      expect(store.needsRefresh(leadMs: 0), isTrue);
      store.accept(
        begin({'a'}),
        body({'a': (30, 6)}, window: 60),
        policy: policy,
      );
      final cov = store.coverageRemainingMs();
      expect(cov, closeTo((nowSec + 60) * 1000 - serverNow, 1));
      expect(store.needsRefresh(leadMs: 10000), isFalse);
      tick += cov - 5000;
      expect(store.needsRefresh(leadMs: 10000), isTrue);
      expect(store.needsRefresh(leadMs: 1000), isFalse);
      tick += cov;
      expect(store.coverageRemainingMs(), 0);
      expect(() => store.needsRefresh(leadMs: -1), throwsArgumentError);
    });

    test('clear removes codes and coverage', () {
      store.accept(begin({'a'}), body({'a': (30, 6)}), policy: policy);
      store.clear();
      expect(store.current('a'), isNull);
      expect(store.coverageRemainingMs(), 0);
      expect(store.needsRefresh(leadMs: 0), isTrue);
    });

    test('BatchCode toString is redacted', () {
      store.accept(begin({'a'}), body({'a': (30, 6)}), policy: policy);
      final c = store.current('a')!;
      expect(c.toString(), isNot(contains(c.value)));
    });
  });
}
