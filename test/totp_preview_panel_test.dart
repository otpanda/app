import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_read_contract.dart';
import 'package:otpanda_client/totp_preview_panel.dart';

class Fake implements SessionTransport {
  String code = '001234';
  int calls = 0;
  Completer<SessionResponse>? pending;
  @override
  Future<SessionResponse> getManagement(String p) async {
    calls++;
    if (p.endsWith('/session')) {
      return SessionResponse(
        200,
        jsonEncode({'ownerId': 'owner', 'expiresAt': 90000}),
      );
    }
    return pending?.future ??
        Future.value(
          SessionResponse(
            200,
            jsonEncode({
              'entryId': 'entry',
              'code': code,
              'period': 30,
              'validFrom': 30,
              'validUntil': 60,
              'serverNow': 59000,
            }),
          ),
        );
  }

  @override
  Future<void> close() async {}
}

Widget host(
  TotpReadStore store, {
  Object scope = 'one',
  String entry = 'entry',
}) => MaterialApp(
  theme: ThemeData(fontFamily: 'Figtree'),
  home: Scaffold(
    body: TotpPreviewPanel(store: store, entryId: entry, scopeKey: scope),
  ),
);
void main() {
  testWidgets('padded seven digits fit at mobile width', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final transport = Fake()..code = '0000001';
    final store = TotpReadStore(transport, monotonicMilliseconds: () => 0);
    await t.pumpWidget(host(store));
    await t.tap(find.text('Load fictional code'));
    await t.pumpAndSettle();
    expect(find.text('000 0001'), findsOneWidget);
    expect(t.takeException(), isNull);
    final box = t.getRect(find.text('000 0001'));
    expect(box.left, greaterThanOrEqualTo(0));
    expect(box.right, lessThanOrEqualTo(390));
    expect(box.width, greaterThan(0));
    await t.pumpWidget(const SizedBox());
    store.clear();
  });

  testWidgets(
    'explicit load shows leading zeros and clears at monotonic expiry without refetch',
    (t) async {
      var tick = 0;
      final transport = Fake();
      final actual = TotpReadStore(
        transport,
        monotonicMilliseconds: () => tick,
      );
      await t.pumpWidget(host(actual));
      expect(find.text('------'), findsOneWidget);
      expect(transport.calls, 0);
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      await t.pump();
      expect(find.text('001 234'), findsOneWidget);
      expect(find.text('Expires in 1 second'), findsOneWidget);
      tick = 1000;
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('001 234'), findsNothing);
      expect(transport.calls, 2);
      expect(find.byIcon(Icons.copy), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('every nonresumed lifecycle clears, resume never reloads', (
    t,
  ) async {
    var tick = 0;
    final transport = Fake();
    final actual = TotpReadStore(transport, monotonicMilliseconds: () => tick);
    await t.pumpWidget(host(actual));
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      await t.pump();
      expect(find.text('001 234'), findsOneWidget);
      final calls = transport.calls;
      t.binding.handleAppLifecycleStateChanged(state);
      await t.pump();
      expect(find.text('001 234'), findsNothing);
      expect(actual.visible(), null);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(transport.calls, calls);
      expect(find.text('001 234'), findsNothing);
    }
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'pending response after background or scope change cannot restore code',
    (t) async {
      final transport = Fake();
      final actual = TotpReadStore(transport, monotonicMilliseconds: () => 0);
      await t.pumpWidget(host(actual));
      transport.pending = Completer<SessionResponse>();
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await t.pump();
      transport.pending!.complete(
        SessionResponse(
          200,
          jsonEncode({
            'entryId': 'entry',
            'code': '001234',
            'period': 30,
            'validFrom': 30,
            'validUntil': 60,
            'serverNow': 59000,
          }),
        ),
      );
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(find.text('001 234'), findsNothing);
      transport.pending = null;
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      await t.pump();
      expect(find.text('001 234'), findsOneWidget);
      await t.pumpWidget(host(actual, scope: 'two'));
      expect(find.text('001 234'), findsNothing);
      expect(actual.visible(), null);
      await t.pumpWidget(const SizedBox());
      expect(actual.visible(), null);
    },
  );
  testWidgets(
    'pending completions cannot survive entry, scope, store or disposal changes',
    (t) async {
      for (final change in ['entry', 'scope', 'store', 'dispose']) {
        final transport = Fake()..pending = Completer<SessionResponse>();
        final store = TotpReadStore(transport, monotonicMilliseconds: () => 0);
        final replacement = TotpReadStore(
          Fake(),
          monotonicMilliseconds: () => 0,
        );
        await t.pumpWidget(host(store));
        await t.tap(find.text('Load fictional code'));
        await t.pump();
        await t.pumpWidget(switch (change) {
          'entry' => host(store, entry: 'other'),
          'scope' => host(store, scope: 'other'),
          'store' => host(replacement),
          _ => const SizedBox(),
        });
        transport.pending!.complete(
          SessionResponse(
            200,
            jsonEncode({
              'entryId': 'entry',
              'code': '001234',
              'period': 30,
              'validFrom': 30,
              'validUntil': 60,
              'serverNow': 59000,
            }),
          ),
        );
        await t.pump();
        await t.pump();
        expect(store.visible(), null);
        expect(replacement.visible(), null);
        expect(find.text('001 234'), findsNothing);
        expect(t.takeException(), null);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'failed load is generic and store cancellation suppresses stale failure',
    (t) async {
      final transport = Fake()..pending = Completer<SessionResponse>();
      final store = TotpReadStore(transport, monotonicMilliseconds: () => 0);
      await t.pumpWidget(host(store));
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      transport.pending!.complete(SessionResponse(403, 'private failure'));
      await t.pump();
      await t.pump();
      expect(
        find.text('Could not load the fictional code. Try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('private failure'), findsNothing);
      transport.pending = Completer<SessionResponse>();
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      await t.pumpWidget(host(store, scope: 'new'));
      transport.pending!.complete(SessionResponse(403, 'private failure'));
      await t.pump();
      await t.pump();
      expect(
        find.text('Could not load the fictional code. Try again.'),
        findsNothing,
      );
      expect(find.text('001 234'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('small and large layout fit without overflow', (t) async {
    for (final size in [const Size(320, 700), const Size(1280, 800)]) {
      t.view.resetPhysicalSize();
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      final store = TotpReadStore(Fake(), monotonicMilliseconds: () => 0);
      await t.pumpWidget(host(store));
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      await t.pump();
      expect(t.takeException(), null);
      await t.pumpWidget(const SizedBox());
    }
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}
