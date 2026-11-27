import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge implements BrowserSessionBridge, RealtimeBridge {
  final listeners = <void Function(String)>[];
  var unsubscribed = 0;
  @override
  void Function() realtimeSubscribe(void Function(String) l) {
    listeners.add(l);
    return () {
      listeners.remove(l);
      unsubscribed++;
    };
  }

  void hint([String r = 'changed']) {
    for (final l in [...listeners]) {
      l(r);
    }
  }

  String state = 'restored';
  final paths = <String>[];
  Future<SessionResponse> Function(String)? handler;
  @override
  String get status => state;
  @override
  Future<void> get ready async {}
  @override
  void clear() {
    state = 'idle';
  }

  @override
  void logout() {
    state = 'idle';
  }

  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {}
  @override
  Future<SessionResponse> organize(String method, String body) async =>
      const SessionResponse(404, '{}');
  @override
  Future<SessionResponse> copied(String entryId, int createdAt) async =>
      const SessionResponse(404, '{}');
  @override
  Future<SessionResponse> read(String path) async {
    paths.add(path);
    if (handler != null) return handler!(path);
    return SessionResponse(
      200,
      jsonEncode(
        path.endsWith('/session')
            ? {'ownerId': 'owner', 'expiresAt': 1000000}
            : path.endsWith('/entries')
            ? {
                'entries': [
                  {
                    'entry_id': 'entry',
                    'service_name': 'Fictional',
                    'capabilities': {'manage': true},
                  },
                ],
              }
            : path.endsWith('/sources')
            ? {'sources': []}
            : {'records': []},
      ),
    );
  }
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  testWidgets('local mutation queues one refresh behind the gate', (
    tester,
  ) async {
    var now = 100;
    final b = Bridge();
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    await c.refresh();
    c.refreshAfterMutation();
    c.refreshAfterMutation();
    expect(b.paths.length, 6);
    now += 15000;
    await tester.pump(const Duration(seconds: 15));
    expect(b.paths.length, 12);
    now += 60000;
    await tester.pump(const Duration(seconds: 60));
    expect(b.paths.length, 12);
    c.dispose();
  });
  testWidgets('transport loss clears across preserved settings lifecycle', (
    tester,
  ) async {
    final b = Bridge();
    final c = ReadWorkspaceController(bridge: b, clock: () => 100);
    c.resume();
    b.hint('connection-lost');
    expect(c.connectionLost, true);
    c.suspend(preserve: true);
    c.resume();
    expect(c.connectionLost, false);
    c.dispose();
  });
  testWidgets('huge read Retry-After is capped at 300 seconds', (tester) async {
    var now = 100;
    final b = Bridge()
      ..handler = (_) async =>
          const SessionResponse(429, '{}', retryAfterSeconds: 999999999);
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    await c.refresh();
    now += 299000;
    await tester.pump(const Duration(seconds: 299));
    expect(b.paths.length, 1);
    b.handler = null;
    now += 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(c.hasLoaded, true);
    c.dispose();
  });
  testWidgets(
    'failed read retries once without hints and stops after success',
    (tester) async {
      var now = 100;
      final b = Bridge();
      b.handler = (_) async => const SessionResponse(503, '{}');
      final c = ReadWorkspaceController(bridge: b, clock: () => now);
      c.resume();
      await c.refresh();
      expect(b.paths.length, 1);
      b.handler = null;
      now += 15000;
      await tester.pump(const Duration(seconds: 15));
      expect(c.hasLoaded, true);
      expect(b.paths.length, 7);
      now += 180000;
      await tester.pump(const Duration(seconds: 180));
      expect(b.paths.length, 7);
      expect(c.connectionLost, false);
      c.dispose();
    },
  );
  testWidgets('429 retry honors server delay beyond the existing floor', (
    tester,
  ) async {
    var now = 100;
    final b = Bridge()
      ..handler = (_) async =>
          const SessionResponse(429, '{}', retryAfterSeconds: 90);
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    await c.refresh();
    now += 60000;
    await tester.pump(const Duration(seconds: 60));
    expect(b.paths.length, 1);
    b.handler = null;
    now += 30000;
    await tester.pump(const Duration(seconds: 30));
    expect(c.hasLoaded, true);
    c.dispose();
  });
  testWidgets(
    'persistent read loss survives transport restore; clear cancels retries',
    (tester) async {
      var now = 100;
      final b = Bridge()
        ..handler = (_) async => const SessionResponse(503, '{}');
      final c = ReadWorkspaceController(bridge: b, clock: () => now);
      c.resume();
      await c.refresh();
      for (var i = 0; i < 8; i++) {
        now += 15000;
        await tester.pump(const Duration(seconds: 15));
      }
      expect(c.connectionLost, true);
      b.hint('connection-restored');
      expect(c.connectionLost, true);
      final count = b.paths.length;
      c.clear();
      now += 180000;
      await tester.pump(const Duration(seconds: 180));
      expect(b.paths.length, count);
      expect(c.connectionLost, false);
      c.dispose();
    },
  );
  testWidgets('suspend and dispose cancel failure retry and warning timers', (
    tester,
  ) async {
    for (final dispose in [false, true]) {
      var now = 100;
      final b = Bridge()
        ..handler = (_) async => const SessionResponse(503, '{}');
      final c = ReadWorkspaceController(bridge: b, clock: () => now);
      await c.refresh();
      if (dispose) {
        c.dispose();
      } else {
        c.suspend(preserve: true);
      }
      now += 180000;
      await tester.pump(const Duration(seconds: 180));
      expect(b.paths.length, 1);
      if (!dispose) c.dispose();
    }
  });

  test(
    'clock ticks never poll and state-only or unknown reasons never fetch',
    () async {
      var now = 100;
      final b = Bridge();
      final c = ReadWorkspaceController(bridge: b, clock: () => now);
      c.resume();
      await c.refresh();
      expect(b.paths.length, 6);
      for (var i = 0; i < 200; i++) {
        now += 1000;
        c.tick();
      }
      await settle();
      expect(b.paths.length, 6);
      b.hint('connection-lost');
      expect(c.connectionLost, true);
      b.hint('unknown');
      b.hint('connection-restored');
      expect(c.connectionLost, false);
      await settle();
      expect(b.paths.length, 6);
      b.hint('connect');
      await settle();
      expect(b.paths.length, 12);
      b.hint('connection-lost');
      c.resetSession();
      expect(c.connectionLost, false);
      c.dispose();
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  test('subscribes once while signed in, never when signed out', () {
    var now = 100;
    final out = Bridge()..state = 'idle';
    final c0 = ReadWorkspaceController(bridge: out, clock: () => now);
    c0.tick();
    expect(out.listeners, isEmpty);
    c0.dispose();
    final b = Bridge();
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    c.tick();
    c.tick();
    c.resume();
    expect(b.listeners, hasLength(1));
    c.dispose();
    expect(b.listeners, isEmpty);
    expect(b.unsubscribed, 1);
  });

  test('a hint refreshes at once when the gate is open', () async {
    var now = 100;
    final b = Bridge();
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    c.tick();
    await settle();
    final before = b.paths.length;
    now += 15000;
    b.hint();
    await settle();
    expect(b.paths.length, before + 6);
    c.dispose();
  });

  test('hints inside the 15 s gate collapse to one trailing refresh', () async {
    var now = 100;
    final b = Bridge();
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    await c.refresh();
    c.resume();
    c.tick();
    await settle();
    final before = b.paths.length;
    b.hint();
    b.hint('connect');
    b.hint();
    await settle();
    expect(b.paths.length, before, reason: 'gate still closed');
    now += 15000;
    await Future<void>.delayed(const Duration(milliseconds: 15100));
    await settle();
    expect(b.paths.length, before + 6, reason: 'exactly one trailing refresh');
    c.dispose();
  });

  test('a hint during a refresh runs one refresh after it', () async {
    var now = 100;
    final b = Bridge();
    final pending = Completer<SessionResponse>();
    b.handler = (_) => pending.future;
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    c.resume();
    unawaited(c.refresh());
    await settle();
    expect(c.loading, true);
    b.hint();
    b.hint();
    final inFlight = b.paths.length;
    b.handler = null;
    pending.complete(
      SessionResponse(200, jsonEncode({'ownerId': 'o', 'expiresAt': 1000000})),
    );
    await settle();
    expect(c.loading, false);
    expect(b.paths.length, greaterThanOrEqualTo(inFlight));
    now += 15000;
    await Future<void>.delayed(const Duration(milliseconds: 15100));
    await settle();
    expect(b.paths.length, greaterThan(inFlight));
    c.dispose();
  });

  test(
    'suspend unsubscribes, later hints do nothing, resume re-subscribes',
    () async {
      var now = 100;
      final b = Bridge();
      final c = ReadWorkspaceController(bridge: b, clock: () => now);
      c.tick();
      await settle();
      expect(b.listeners, hasLength(1));
      c.suspend();
      expect(b.listeners, isEmpty);
      final n = b.paths.length;
      b.hint();
      await settle();
      expect(b.paths.length, n);
      c.resume();
      expect(b.listeners, hasLength(1));
      c.dispose();
    },
  );

  test('401 ends the session and the subscription; dispose cancels a pending trailing refresh', () async {
    var now = 100;
    final b = Bridge();
    final c = ReadWorkspaceController(bridge: b, clock: () => now);
    await c.refresh();
    c.tick();
    expect(b.listeners, hasLength(1));
    b.hint();
    c.dispose();
    expect(b.listeners, isEmpty);
    final n = b.paths.length;
    await Future<void>.delayed(const Duration(milliseconds: 15100));
    expect(b.paths.length, n);
    final b2 = Bridge();
    final c2 = ReadWorkspaceController(bridge: b2, clock: () => now);
    c2.tick();
    await settle();
    now += 15000;
    b2.handler = (_) async => const SessionResponse(401, '{}');
    b2.hint();
    await settle();
    expect(b2.listeners, isEmpty);
    expect(c2.sessionEnded, true);
    c2.dispose();
  });
}
