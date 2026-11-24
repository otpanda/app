import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';

class FakeTransport implements BrowserSessionBridge {
  String state = 'restored';
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
    clear();
  }

  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {}
  @override
  Future<SessionResponse> organize(String method, String body) async =>
      const SessionResponse(404, '{}');
  @override
  Future<SessionResponse> copied(String id, int at) async =>
      const SessionResponse(404, '{}');
  final Map<String, SessionResponse> routes;
  int calls = 0;
  FakeTransport(this.routes);
  @override
  Future<SessionResponse> read(String path) async {
    calls++;
    return routes[path] ?? const SessionResponse(500, '{}');
  }
}

SessionResponse ok(Object o) => SessionResponse(200, jsonEncode(o));
const now = 1000000;
Map<String, SessionResponse> routes({
  List entries = const [],
  List codes = const [],
}) => {
  '/v1/manage/session': ok({'ownerId': 'o', 'expiresAt': now + 600000}),
  '/v1/manage/entries': ok({'entries': entries}),
  '/v1/manage/active-codes': ok({'records': codes}),
  '/v1/manage/sources': ok({'sources': []}),
  '/v1/manage/unassigned': ok({'records': []}),
};

Future<void> pump(WidgetTester t, FakeTransport tr, {bool out = false}) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final controller = ReadWorkspaceController(bridge: tr, clock: () => now);
  addTearDown(controller.dispose);
  await controller.refresh();
  await t.pumpWidget(
    MaterialApp(
      theme: otpandaTheme(),
      home: ProductShell(
        controller: controller,
        onCopyAssigned: (_) async {},
        onCopyPrivate: (_) async {},
        clock: () => now,
        onSignedOut: () {},
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('genuine empty account shows empty state, no demo data', (
    t,
  ) async {
    await pump(t, FakeTransport(routes()));
    expect(find.text('No codes yet'), findsOneWidget);
    expect(find.text('Northstar'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('loaded entry shows its active code', (t) async {
    await pump(
      t,
      FakeTransport(
        routes(
          entries: [
            {
              'entry_id': 'e1',
              'service_name': 'Acme',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'e1',
              'code': '123456',
              'receivedAt': now - 1000,
              'expiresAt': now + 60000,
            },
          ],
        ),
      ),
    );
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('123 456'), findsOneWidget);
  });

  testWidgets('failed read is not shown as an empty account', (t) async {
    await pump(t, FakeTransport({}));
    expect(find.text('Could not load your codes'), findsOneWidget);
    expect(find.text('No codes yet'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('429 offers manual retry without auto-retrying', (t) async {
    final tr = FakeTransport({
      '/v1/manage/session': const SessionResponse(429, '{}'),
    });
    await pump(t, tr);
    expect(find.text('Too many requests'), findsOneWidget);
    final calls = tr.calls;
    await t.pump(const Duration(seconds: 5));
    expect(tr.calls, calls);
  });

  testWidgets(
    '401 clears authority and offers sign-in without empty-account claim',
    (t) async {
      final bridge = FakeTransport({
        '/v1/manage/session': const SessionResponse(401, '{}'),
      });
      await pump(t, bridge);
      expect(bridge.status, 'idle');
      expect(find.text('No codes yet'), findsNothing);
      expect(find.text('Acme'), findsNothing);
      expect(find.text('123 456'), findsNothing);
    },
  );
  testWidgets('background-cleared data never claims the account is empty', (
    t,
  ) async {
    final bridge = FakeTransport(routes());
    final controller = ReadWorkspaceController(
      bridge: bridge,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    controller.suspend();
    controller.resume();
    await t.pumpWidget(
      MaterialApp(
        home: ProductShell(
          controller: controller,
          clock: () => now,
          onSignedOut: () {},
          onCopyAssigned: (_) async {},
          onCopyPrivate: (_) async {},
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Refresh to load your codes'), findsOneWidget);
    expect(find.text('No codes yet'), findsNothing);
    expect(bridge.calls, 5);
  });
}
