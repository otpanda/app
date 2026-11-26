import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart' show NativeSession;
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_bridge.dart' show BearerRequest;
import 'package:otpanda_client/native/native_device_startup.dart';
import 'package:otpanda_client/native/native_enroll_recovery.dart';
import 'package:otpanda_client/session_contract.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';

class _Src implements DeviceProofSource {
  int signs = 0, creates = 0;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => true;
  @override
  Future<Uint8List?> publicKeyOrNull() async => base64.decode(_spki);
  @override
  Future<Uint8List> createKeyForEnrollment() async {
    creates++;
    return base64.decode(_spki);
  }

  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    throw StateError('never signs at startup');
  }
}

class _Store implements PendingEnrollStore {
  PendingRead st = const PendingRead.none();
  bool cleared = false;
  @override
  Future<PendingRead> read() async => st;
  @override
  Future<void> write(PendingRecord r) async => st = PendingRead.record(r);
  @override
  Future<void> clear() async => cleared = true;
}

const _session = NativeSession('DEV', 'tok-access', 99999999);

void main() {
  test('disabled (default): no request, no read, nothing changes', () async {
    expect(nativeAuthEnabled, isFalse);
    var calls = 0;
    final s = _Src();
    final r = await runNativeStartupRecovery(
      session: _session,
      source: s,
      store: _Store(),
      enabled: false,
      request: (m, p, {body, query, required bearer}) async {
        calls++;
        return const SessionResponse(200, '{}');
      },
    );
    expect(r, isNull);
    expect(calls, 0);
    expect(s.signs + s.creates, 0);
  });

  test('signed out, or owner unreadable: null and nothing touched', () async {
    final st = _Store();
    expect(
      await runNativeStartupRecovery(
        session: null,
        source: _Src(),
        store: st,
        enabled: true,
        request: (m, p, {body, query, required bearer}) async =>
            const SessionResponse(200, '{}'),
      ),
      isNull,
    );
    for (final res in [
      const SessionResponse(500, '{}'),
      const SessionResponse(200, 'x'),
      const SessionResponse(200, '{"ownerId":""}'),
    ]) {
      expect(
        await runNativeStartupRecovery(
          session: _session,
          source: _Src(),
          store: st,
          enabled: true,
          request: (m, p, {body, query, required bearer}) async => res,
        ),
        isNull,
      );
    }
    expect(st.cleared, isFalse);
  });

  test('enabled, no record: nothing, with only the read-only session GET; bearer is the session access token', () async {
    final seen = <String>[];
    final r = await runNativeStartupRecovery(
      session: _session,
      source: _Src(),
      store: _Store(),
      enabled: true,
      request: (m, p, {body, query, required bearer}) async {
        seen.add('$m $p $bearer');
        return const SessionResponse(200, '{"ownerId":"O","expiresAt":5}');
      },
    );
    expect(r!.outcome, RecoveryOutcome.nothing);
    expect(seen, ['GET /v1/manage/session tok-access']);
  });

  test('unreadable record: anchors the start, asks enroll-status with the exact digest body over the bearer, never signs or creates', () async {
    final st = _Store()..st = const PendingRead.unreadable();
    final s = _Src();
    final posts = <String>[];
    final r = await runNativeStartupRecovery(
      session: _session,
      source: s,
      store: st,
      enabled: true,
      now: () => 5000,
      request: (m, p, {body, query, required bearer}) async {
        if (m == 'GET') return const SessionResponse(200, '{"ownerId":"O"}');
        posts.add('$p ${body!}');
        expect(bearer, 'tok-access');
        return const SessionResponse(
          200,
          '{"status":"enrolled","keyId":"k_0000000000000000000000000000000000000000"}',
        );
      },
    );
    expect(r!.outcome, RecoveryOutcome.needsAdopt);
    expect(
      posts.single,
      startsWith('/v1/manage/device-key/enroll-status {"digest":"'),
    );
    expect(st.st.record, isNotNull, reason: 'anchor persisted');
    expect(st.cleared, isFalse);
    expect(s.signs + s.creates, 0);
  });

  NativeStartupRecovery mk(
    BearerRequest req,
    _Store st, {
    AsyncLock? lock,
    int Function()? now,
  }) => NativeStartupRecovery(
    request: req,
    source: _Src(),
    store: st,
    enabled: true,
    lock: lock,
    now: now,
  );

  test('result is bound to owner+device; sign-out clears; a different device clears and reruns', () async {
    final st = _Store();
    final c = mk(
      (m, p, {body, query, required bearer}) async =>
          const SessionResponse(200, '{"ownerId":"O"}'),
      st,
    );
    await c.sessionChanged(_session);
    expect(c.current!.ownerId, 'O');
    expect(c.current!.deviceId, 'DEV');
    expect(c.current!.result.outcome, RecoveryOutcome.nothing);
    await c.sessionChanged(null);
    expect(c.current, isNull);
    await c.sessionChanged(const NativeSession('DEV2', 'tok2', 99999999));
    expect(c.current!.deviceId, 'DEV2');
  });

  test(
    'a late result for a signed-out or replaced session is discarded',
    () async {
      final gate = Completer<void>();
      final st = _Store();
      final c = mk((m, p, {body, query, required bearer}) async {
        if (bearer == 'tok-access') await gate.future;
        return const SessionResponse(200, '{"ownerId":"O"}');
      }, st);
      final first = c.sessionChanged(_session);
      await Future<void>.delayed(Duration.zero);
      await c.sessionChanged(null); // sign out while in flight
      gate.complete();
      await first;
      expect(c.current, isNull);
      // replaced by another device while the first is in flight
      final gate2 = Completer<void>();
      final c2 = mk((m, p, {body, query, required bearer}) async {
        if (bearer == 'tok-access') await gate2.future;
        return const SessionResponse(200, '{"ownerId":"O"}');
      }, _Store());
      final f2 = c2.sessionChanged(_session);
      await Future<void>.delayed(Duration.zero);
      await c2.sessionChanged(const NativeSession('DEV2', 'tok2', 99999999));
      gate2.complete();
      await f2;
      expect(c2.current!.deviceId, 'DEV2');
    },
  );

  test('an offline failure retries only after the growing gap; a settled outcome does not rerun', () async {
    var fail = true;
    var gets = 0;
    var t = 1000000;
    final c = mk(
      (m, p, {body, query, required bearer}) async {
        gets++;
        return fail
            ? const SessionResponse(503, '{}')
            : const SessionResponse(200, '{"ownerId":"O"}');
      },
      _Store(),
      now: () => t,
    );
    await c.sessionChanged(_session);
    expect(c.current, isNull);
    expect(gets, 1);
    fail = false;
    t += 14000; // inside the 15 s gap: no request
    await c.sessionChanged(_session);
    expect(gets, 1);
    t += 2000;
    await c.sessionChanged(_session);
    expect(c.current!.result.outcome, RecoveryOutcome.nothing);
    final before = gets;
    await c.sessionChanged(_session);
    expect(gets, before, reason: 'settled: no rerun');
  });

  test('frequent controller notifications make no request burst; gaps grow, cap at 10 min, and honour Retry-After', () async {
    var gets = 0;
    int? ra;
    var t = 0;
    final c = mk(
      (m, p, {body, query, required bearer}) async {
        gets++;
        return SessionResponse(503, '{}', retryAfterSeconds: ra);
      },
      _Store(),
      now: () => t,
    );
    for (var i = 0; i < 200; i++) {
      await c.sessionChanged(_session);
      t += 50;
    }
    expect(gets, 1, reason: '200 notifications in 10 s: one request');
    final times = <int>[];
    for (var k = 0; k < 8; k++) {
      final before = gets;
      while (gets == before) {
        t += 1000;
        await c.sessionChanged(_session);
      }
      times.add(t);
    }
    final gaps = [
      for (var i = 1; i < times.length; i++) times[i] - times[i - 1],
    ];
    expect(
      gaps.first,
      greaterThanOrEqualTo(29000),
      reason: 'second failure waits 30 s',
    );
    for (var i = 1; i < gaps.length; i++) {
      expect(gaps[i], greaterThanOrEqualTo(gaps[i - 1]));
    }
    expect(gaps.last, lessThanOrEqualTo(601000));
    expect(gaps.last, greaterThanOrEqualTo(480000));
    ra = 1800; // Retry-After 30 min beats the capped gap
    t += 700000;
    await c.sessionChanged(_session);
    final g = gets;
    t += 1700000;
    await c.sessionChanged(_session);
    expect(gets, g, reason: 'still inside Retry-After');
    t += 200000;
    await c.sessionChanged(_session);
    expect(gets, g + 1);
  });

  test('waiting waits for waitUntilMs, not a poll', () async {
    // Unreadable slot anchored at t=1,000,000: absent before the floor => waiting.
    final st = _Store()..st = const PendingRead.unreadable();
    var posts = 0;
    var t = 1000000;
    final c = mk(
      (m, p, {body, query, required bearer}) async {
        if (m == 'GET') return const SessionResponse(200, '{"ownerId":"O"}');
        posts++;
        return const SessionResponse(200, '{"status":"absent"}');
      },
      st,
      now: () => t,
    );
    await c.sessionChanged(_session);
    expect(c.current!.result.outcome, RecoveryOutcome.waiting);
    expect(posts, 1);
    t += 60000;
    for (var i = 0; i < 20; i++) {
      await c.sessionChanged(_session);
    }
    expect(posts, 1, reason: 'before waitUntilMs: no request');
    t += 61000;
    await c.sessionChanged(_session);
    expect(posts, 2);
  });

  test('a renewed token re-verifies the owner; the same owner keeps the settled result, another owner drops it', () async {
    var owner = 'O';
    var gets = 0;
    var t = 0;
    final c = mk(
      (m, p, {body, query, required bearer}) async {
        gets++;
        return SessionResponse(200, '{"ownerId":"$owner"}');
      },
      _Store(),
      now: () => t,
    );
    await c.sessionChanged(_session);
    expect(c.current!.ownerId, 'O');
    final base = gets;
    await c.sessionChanged(_session);
    expect(gets, base, reason: 'same token: reuse, no request');
    await c.sessionChanged(const NativeSession('DEV', 'renewed', 99999999));
    expect(c.current!.ownerId, 'O');
    expect(c.current!.access, 'renewed');
    owner = 'P';
    await c.sessionChanged(const NativeSession('DEV', 'renewed2', 99999999));
    expect(
      c.current!.ownerId,
      'P',
      reason: 'owner changed: old result not reused',
    );
  });

  test('startup refuses a locked store (deadlock); the devices service refuses an unlocked enroll store', () {
    final lock = AsyncLock();
    final raw = _Store();
    expect(
      () => NativeStartupRecovery(
        request: (m, p, {body, query, required bearer}) async =>
            const SessionResponse(200, '{}'),
        source: _Src(),
        store: LockedPendingStore(raw, lock),
        enabled: true,
        lock: lock,
      ),
      throwsArgumentError,
    );
  });

  test(
    'recovery and enroll store writes are serialized behind one lock',
    () async {
      final log = <String>[];
      final lock = AsyncLock();
      final inner = _SlowStore(log);
      final locked = LockedPendingStore(inner, lock);
      final c = NativeStartupRecovery(
        request: (m, p, {body, query, required bearer}) async =>
            const SessionResponse(200, '{"ownerId":"O"}'),
        source: _Src(),
        store: inner,
        enabled: true,
        lock: lock,
      );
      final rec = c.sessionChanged(_session);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final w = locked.clear();
      await Future.wait([rec, w]);
      expect(log, ['read:start', 'read:end', 'clear:start', 'clear:end']);
    },
  );

  test('bearerDevicePost over the real bearer client sends exactly application/json and the body', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    addTearDown(() => server.close(force: true));
    final seen = <Map<String, String?>>[];
    server.listen((r) async {
      final b = await utf8.decodeStream(r);
      seen.add({
        'ct': r.headers.value('content-type'),
        'auth': r.headers.value('authorization'),
        'body': b,
        'path': r.uri.path,
      });
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"status":"absent"}');
      await r.response.close();
    });
    final post = bearerDevicePost(
      androidBearerRequest('http://127.0.0.1:${server.port}'),
      () => 'tok',
    );
    final r = await post('/v1/manage/device-key/enroll-status', {
      'digest': 'd' * 64,
    });
    expect(r.status, 200);
    expect(r.body, {'status': 'absent'});
    expect(seen.single['ct'], 'application/json');
    expect(seen.single['auth'], 'Bearer tok');
    expect(seen.single['body'], '{"digest":"${'d' * 64}"}');
  });
}

class _SlowStore extends _Store {
  _SlowStore(this.log);
  final List<String> log;
  @override
  Future<PendingRead> read() async {
    log.add('read:start');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    log.add('read:end');
    return st;
  }

  @override
  Future<void> clear() async {
    log.add('clear:start');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    log.add('clear:end');
  }
}
