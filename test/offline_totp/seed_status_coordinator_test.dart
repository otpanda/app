import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_status_coordinator.dart';

class Native implements SeedStatusNative {
  @override
  Future<SeedStatusOwners> owners() async => discovered;
  SeedStatusOwners discovered = const SeedStatusOwners([
    'signed-out-owner',
  ], pendingOrUnreadable: false);
  bool signThrows = false, applyThrows = false;
  String? key = 'keyA';
  String outcome = 'PURGED';
  int retries = 0, signs = 0, applies = 0;
  String? asked, appliedState;
  @override
  Future<String?> activeKeyId(String owner) async => key;
  @override
  Future<void> retryPending() async {
    retries++;
  }

  @override
  Future<String> signStatus({
    required String owner,
    required String askedKeyId,
    required String challenge,
    required int expiresAt,
  }) async {
    if (signThrows) throw StateError("sign");
    signs++;
    asked = askedKeyId;
    return 'synthetic-signature';
  }

  @override
  Future<String> applyStatus({
    required String owner,
    required String askedKeyId,
    required String state,
  }) async {
    if (applyThrows) throw StateError("apply");
    applies++;
    asked = askedKeyId;
    appliedState = state;
    return key == askedKeyId ? outcome : 'NOOP';
  }
}

class Transport implements SeedStatusTransport {
  int calls = 0, finishStatus = 200;
  String body = '{"state":"key-revoked"}';
  bool wrongKey = false;
  Object? expiry = 1800000120000;
  String token = 'synthetic-token';
  Completer<void>? pause;
  void Function()? beforeFinish;
  @override
  Future<SeedStatusResponse> post(String path, Map<String, Object> body) async {
    calls++;
    await pause?.future;
    if (path.endsWith('status-begin')) {
      return SeedStatusResponse(
        200,
        jsonEncode({
          'token': token,
          'challenge': {
            'keyId': wrongKey ? 'keyB' : body['keyId'],
            'challenge': 'A' * 43,
            'expiresAt': expiry,
          },
        }),
      );
    }
    beforeFinish?.call();
    return SeedStatusResponse(finishStatus, this.body);
  }
}

void main() {
  test('native discovery works without any session', () async {
    final n = Native(), t = Transport();
    expect(
      (await SeedStatusCoordinator(
        t,
        n,
      ).checkAll()).results['signed-out-owner'],
      SeedStatusResult.purged,
    );
  });
  test(
    'incomplete discovery still checks healthy owners, not empty success',
    () async {
      final n = Native()
            ..discovered = const SeedStatusOwners([
              'healthy',
            ], pendingOrUnreadable: true),
          t = Transport();
      final sweep = await SeedStatusCoordinator(t, n).checkAll();
      expect(sweep.incomplete, true);
      expect(sweep.results['healthy'], SeedStatusResult.purged);
      expect(t.calls, 2);
      expect(n.applies, 1);
    },
  );
  test('native pending, unreadable and unknown outcomes retry', () async {
    for (final outcome in ['PENDING', 'UNREADABLE', 'unexpected']) {
      final n = Native()..outcome = outcome;
      expect(
        await SeedStatusCoordinator(Transport(), n).check('owner'),
        SeedStatusResult.retry,
      );
    }
  });
  test('kept throttle is fifteen minutes, in memory only', () async {
    var now = DateTime(2026);
    final n = Native()..outcome = 'KEPT',
        t = Transport()..body = '{"state":"active"}';
    final c = SeedStatusCoordinator(t, n, clock: () => now);
    expect(await c.check('owner'), SeedStatusResult.kept);
    now = now.add(const Duration(minutes: 14));
    expect(await c.check('owner'), SeedStatusResult.deferred);
    now = now.add(const Duration(minutes: 1));
    expect(await c.check('owner'), SeedStatusResult.kept);
  });
  test('same owner concurrent calls share one begin and finish', () async {
    final n = Native(), t = Transport()..pause = Completer<void>();
    final c = SeedStatusCoordinator(t, n);
    final a = c.check('owner'), b = c.check('owner');
    t.pause!.complete();
    await Future.wait([a, b]);
    expect(t.calls, 2);
  });
  test(
    'sign and apply failures retry locally before any later attempt',
    () async {
      for (final sign in [true, false]) {
        var now = DateTime(2026);
        final n = Native()
              ..signThrows = sign
              ..applyThrows = !sign,
            t = Transport();
        final c = SeedStatusCoordinator(t, n, clock: () => now);
        expect(await c.check('owner'), SeedStatusResult.retry);
        expect(t.calls, sign ? 1 : 2);
        n.signThrows = false;
        n.applyThrows = false;
        now = now.add(const Duration(hours: 1));
        expect(await c.check('owner'), SeedStatusResult.purged);
        expect(n.retries, 2);
      }
    },
  );
  test('token and expiry type bounds refuse before signing', () async {
    for (final expiry in [-1, 9007199254740992, 1.5, '10']) {
      final n = Native(), t = Transport()..expiry = expiry;
      expect(
        await SeedStatusCoordinator(t, n).check('o'),
        SeedStatusResult.retry,
      );
      expect(n.signs, 0);
    }
    for (final token in ['', 'x' * 257]) {
      final n = Native(), t = Transport()..token = token;
      expect(
        await SeedStatusCoordinator(t, n).check('o'),
        SeedStatusResult.retry,
      );
      expect(n.signs, 0);
    }
  });
  test('only exact successful definitive states apply to asked key', () async {
    for (final state in ['active', 'key-revoked', 'generation-changed']) {
      final n = Native()..outcome = state == 'active' ? 'KEPT' : 'PURGED';
      final t = Transport()..body = jsonEncode({'state': state});
      final r = await SeedStatusCoordinator(t, n).check('owner');
      expect(
        r,
        state == 'active' ? SeedStatusResult.kept : SeedStatusResult.purged,
      );
      expect(n.asked, 'keyA');
      expect(n.appliedState, state);
    }
  });
  test(
    'unknown HTTP, malformed and extra fields never apply; retry backs off',
    () async {
      var now = DateTime(2026);
      for (final status in [409, 429, 503, 401, 200]) {
        for (final body in [
          '{}',
          'bad',
          '{"state":"unknown"}',
          '{"state":"key-revoked","extra":true}',
        ]) {
          final n = Native(),
              t = Transport()
                ..finishStatus = status
                ..body = body;
          final c = SeedStatusCoordinator(t, n, clock: () => now);
          expect(await c.check('owner'), SeedStatusResult.retry);
          expect(n.applies, 0);
          final count = t.calls;
          expect(await c.check('owner'), SeedStatusResult.deferred);
          expect(t.calls, count);
          now = now.add(const Duration(minutes: 2));
          await c.check('owner');
          expect(t.calls, greaterThan(count));
        }
      }
    },
  );
  test('pending/no active key retries locally, never calls network', () async {
    final n = Native()..key = null, t = Transport();
    expect(
      await SeedStatusCoordinator(t, n).check('owner'),
      SeedStatusResult.retry,
    );
    expect(n.retries, 1);
    expect(t.calls, 0);
  });
  test('mismatched challenge key never signs', () async {
    final n = Native(), t = Transport()..wrongKey = true;
    expect(
      await SeedStatusCoordinator(t, n).check('owner'),
      SeedStatusResult.retry,
    );
    expect(n.signs, 0);
    expect(n.applies, 0);
  });
  test(
    'old key response never erases new enrollment; NOOP is superseded',
    () async {
      final n = Native(), t = Transport();
      t.beforeFinish = () => n.key = 'keyB';
      expect(
        await SeedStatusCoordinator(t, n).check('owner'),
        SeedStatusResult.superseded,
      );
      expect(n.asked, 'keyA');
      expect(n.key, 'keyB');
    },
  );
}
