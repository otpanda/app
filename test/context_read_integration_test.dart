import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';

import 'read_workspace_controller_test.dart' show Bridge;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final review = {
    'contextId': 'ctx',
    'sourceId': 'src',
    'eventId': 'event',
    'kind': 'email',
    'sender': 'example.test',
    'sourceLabel': 'Personal',
    'receivedAt': 10,
    'arrivedAt': 10,
    'retainedUntil': 100000,
    'redactedText': 'Code [redacted]',
    'contextUnavailable': false,
    'truncated': false,
  };
  for (final status in [404, 429, 503, 200]) {
    test(
      'optional context $status malformed/unavailable cannot remove usable entries',
      () async {
        final base = Bridge();
        final bridge = Bridge()
          ..handler = (path) => path.endsWith('/unassigned-context')
              ? Future.value(SessionResponse(status, '{}'))
              : base.read(path);
        final c = ReadWorkspaceController(bridge: bridge, clock: () => 100);
        addTearDown(c.dispose);
        await c.refresh();
        expect(c.store.entries.single.id, 'entry');
        expect(c.contexts, isEmpty);
        expect(c.hasLoaded, true);
        expect(bridge.status, 'restored');
      },
    );
  }
  test(
    'context-only 401 clears staged and previously published authority',
    () async {
      var now = 100;
      var unauthorized = false;
      final base = Bridge();
      final bridge = Bridge()
        ..handler = (path) => path.endsWith('/unassigned-context')
            ? Future.value(
                unauthorized
                    ? const SessionResponse(401, '{}')
                    : SessionResponse(
                        200,
                        jsonEncode({
                          'contexts': [review],
                        }),
                      ),
              )
            : base.read(path);
      final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
      addTearDown(c.dispose);
      await c.refresh();
      expect(c.contexts, hasLength(1));
      expect(c.store.entries, isNotEmpty);
      unauthorized = true;
      now += 15000;
      await c.refresh();
      expect(c.store.entries, isEmpty);
      expect(c.contexts, isEmpty);
      expect(c.hasLoaded, false);
      expect(bridge.status, 'idle');
    },
  );
  test('pending optional context cannot republish entries or context after suspension', () async {
    final pending = Completer<SessionResponse>();
    final entered = Completer<void>();
    final base = Bridge();
    final bridge = Bridge()
      ..handler = (path) {
        if (path.endsWith('/unassigned-context')) {
          entered.complete();
          return pending.future;
        }
        return base.read(path);
      };
    final c = ReadWorkspaceController(bridge: bridge, clock: () => 100);
    addTearDown(c.dispose);
    final refreshing = c.refresh();
    await entered.future;
    c.suspend();
    pending.complete(
      SessionResponse(
        200,
        jsonEncode({
          'contexts': [review],
        }),
      ),
    );
    await refreshing;
    expect(c.store.entries, isEmpty);
    expect(c.contexts, isEmpty);
    expect(c.hasLoaded, false);
  });
}
