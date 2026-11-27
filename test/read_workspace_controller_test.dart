import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge implements BrowserSessionBridge {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'one refresh uses six read endpoints including optional review context and gates rapid retries',
    () async {
      var now = 100;
      final bridge = Bridge();
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      await c.refresh();
      expect(bridge.paths.length, 6);
      expect(c.store.entries.single.id, 'entry');
      await c.refresh();
      expect(bridge.paths.length, 6);
      expect(c.refreshWaitMs, 15000);
      now += 15000;
      await c.refresh();
      expect(bridge.paths.length, 12);
      c.dispose();
    },
  );
  test(
    'background clears populated data and suppresses late response',
    () async {
      var now = 100;
      final bridge = Bridge();
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      await c.refresh();
      expect(c.store.entries, isNotEmpty);
      expect(c.hasLoaded, true);
      c.suspend();
      expect(c.hasLoaded, false);
      expect(c.store.entries, isEmpty);
      c.resume();
      now += 15000;
      final pending = Completer<SessionResponse>();
      bridge.handler = (_) => pending.future;
      final loading = c.refresh();
      c.suspend();
      pending.complete(
        SessionResponse(
          200,
          jsonEncode({'ownerId': 'owner', 'expiresAt': 1000000}),
        ),
      );
      await loading;
      expect(c.store.entries, isEmpty);
      expect(c.loading, false);
      expect(bridge.paths.length, 7);
      c.dispose();
    },
  );
  test(
    '401 clears browser authority and transient failures remain retryable',
    () async {
      var now = 100;
      final bridge = Bridge();
      bridge.handler = (_) async => const SessionResponse(503, '{}');
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      await c.refresh();
      expect(c.message, 'Could not load codes. Try again.');
      expect(bridge.status, 'restored');
      now += 15000;
      bridge.handler = (_) async => const SessionResponse(401, '{}');
      await c.refresh();
      expect(bridge.status, 'idle');
      expect(c.store.entries, isEmpty);
      expect(c.message, 'Your session ended. Sign in again.');
      c.dispose();
    },
  );
  test(
    'clock alone never starts snapshot reads, including failed initial load',
    () async {
      var now = 100;
      final bridge = Bridge();
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      c.tick();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.paths, isEmpty);
      await c.refresh();
      now += 120000;
      c.tick();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.paths.length, 6);
      c.suspend();
      c.resume();
      now += 15000;
      c.tick();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.paths.length, 6);
      c.dispose();
    },
  );
  test(
    'hint-driven refresh retains snapshot during request and transient failure',
    () async {
      var now = 100;
      final bridge = Bridge();
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      await c.refresh();
      final previous = c.store;
      now += 30000;
      final pending = Completer<SessionResponse>();
      bridge.handler = (_) => pending.future;
      final loading = c.refresh();
      expect(c.store, same(previous));
      expect(c.store.entries, isNotEmpty);
      c.suspend(preserve: true);
      c.resume();
      expect(c.store.entries, isNotEmpty);
      pending.complete(const SessionResponse(503, '{}'));
      await loading;
      expect(c.store, same(previous));
      now += 30000;
      bridge.handler = (_) async => const SessionResponse(503, '{}');
      await c.refresh();
      expect(c.store.entries, isNotEmpty);
      expect(c.hasLoaded, true);
      now += 30000;
      bridge.handler = (_) async => const SessionResponse(401, '{}');
      await c.refresh();
      expect(c.store.entries, isEmpty);
      expect(c.signedIn, false);
      c.dispose();
    },
  );
  test(
    '401 while returning from preserved settings clears retained codes',
    () async {
      var now = 100;
      final bridge = Bridge();
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      await c.refresh();
      c.suspend(preserve: true);
      expect(c.store.entries, isNotEmpty);
      c.resume();
      now += 30000;
      bridge.handler = (_) async => const SessionResponse(401, '{}');
      await c.refresh();
      expect(c.store.entries, isEmpty);
      expect(c.signedIn, false);
      c.dispose();
    },
  );
  test('session expiry clears entry metadata on the next clock tick', () async {
    var now = 100;
    final bridge = Bridge();
    final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
    await c.refresh();
    now = 1000000;
    c.tick();
    expect(c.store.entries, isEmpty);
    expect(c.signedIn, false);
    c.dispose();
  });
  test('fresh completed login can reset an ended workspace but ordinary refresh cannot', () async {
    final bridge = Bridge();
    bridge.handler = (_) async => const SessionResponse(401, '{}');
    final c = ReadWorkspaceController(bridge: bridge, clock: () => 100);
    await c.refresh();
    expect(c.sessionEnded, true);
    bridge.state = 'restored';
    await c.refresh();
    expect(c.sessionEnded, true);
    c.resetSession();
    bridge.handler = null;
    await c.refresh();
    expect(c.store.entries.single.id, 'entry');
    c.dispose();
  });
  test('assigned and private copy recheck expiry and never write expired clipboard data', () async {
    var now = 100;
    final bridge = Bridge();
    bridge.handler = (path) async => SessionResponse(
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
            ? {
                'sources': [
                  {'source_id': 'source', 'kind': 'sms', 'label': 'Fictional'},
                ],
              }
            : path.endsWith('/active-codes')
            ? {
                'records': [
                  {
                    'entryId': 'entry',
                    'code': '123456',
                    'receivedAt': 0,
                    'expiresAt': 200,
                  },
                ],
              }
            : {
                'records': [
                  {
                    'sourceId': 'source',
                    'eventId': 'event',
                    'code': '654321',
                    'receivedAt': 0,
                    'expiresAt': 200,
                  },
                ],
              },
      ),
    );
    final writes = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') writes.add(call.arguments);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
    await c.refresh();
    final assigned = c.store.visibleCodes(now).single,
        private = c.store.visibleUnassigned(now).single;
    expect(c.canCopyAssigned(assigned), true);
    expect(c.canCopyPrivate(private), true);
    await c.copyAssigned(assigned);
    await c.copyPrivate(private);
    expect(writes.length, 2);
    writes.clear();
    now = 200;
    expect(c.canCopyAssigned(assigned), false);
    expect(c.canCopyPrivate(private), false);
    await c.copyAssigned(assigned);
    await c.copyPrivate(private);
    expect(writes, isEmpty);
    c.dispose();
  });
  test('429 extends manual refresh cooldown to sixty seconds', () async {
    var now = 100;
    final bridge = Bridge();
    bridge.handler = (_) async => const SessionResponse(429, '{}');
    final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
    await c.refresh();
    expect(c.refreshWaitMs, 60000);
    now += 59999;
    await c.refresh();
    expect(bridge.paths.length, 1);
    expect(c.canRefresh, false);
    now++;
    expect(c.canRefresh, true);
    await c.refresh();
    expect(bridge.paths.length, 2);
    c.dispose();
  });
}
