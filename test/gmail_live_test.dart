import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart'
    show RealtimeBridge;
import 'package:otpanda_client/gmail_source.dart';
import 'package:otpanda_client/session_contract.dart';

import 'gmail_source_test.dart' show Bridge;

class LiveBridge extends Bridge implements RealtimeBridge {
  final listeners = <void Function(String)>[];
  int starts = 0;
  int subscribed = 0, unsubscribed = 0, active = 0, maxActive = 0;
  Completer<void>? gate;
  bool fail = false;
  @override
  void Function() realtimeSubscribe(void Function(String reason) l) {
    subscribed++;
    listeners.add(l);
    return () {
      unsubscribed++;
      listeners.remove(l);
    };
  }

  void hint([String reason = 'changed']) {
    for (final l in [...listeners]) {
      l(reason);
    }
  }

  @override
  Future<SessionResponse> gmailSourceStatus() async {
    starts++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (gate != null) await gate!.future;
      if (fail) throw StateError('offline');
      return await super.gmailSourceStatus();
    } finally {
      active--;
    }
  }
}

Future<void> openLive(WidgetTester t, LiveBridge b) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(body: GmailSourceConnect(bridge: b)),
    ),
  );
  await t.pumpAndSettle();
}

const gone = MaterialApp(home: SizedBox());

void main() {
  testWidgets(
    'initial read; hints and connect read; connection state does not',
    (t) async {
      final b = LiveBridge();
      await openLive(t, b);
      expect(b.checks, 1);
      expect(b.subscribed, 1);
      b.pending = 3;
      b.hint('connection-lost');
      await t.pump(const Duration(seconds: 95));
      expect(b.checks, 1);
      b.hint();
      await t.pumpAndSettle();
      expect(b.checks, 2);
      expect(find.textContaining('3 messages are waiting'), findsOneWidget);
      b.hint('connect');
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(b.checks, 3);
      await t.pumpWidget(gone);
      expect(b.unsubscribed, 1);
    },
  );
  testWidgets(
    'a burst is one read in flight plus one trailing, never overlapping',
    (t) async {
      final b = LiveBridge();
      await openLive(t, b);
      b.gate = Completer<void>();
      b.hint();
      await t.pump();
      for (var i = 0; i < 5; i++) {
        b.hint();
      }
      await t.pump(const Duration(seconds: 3));
      expect(b.starts, 2, reason: 'one read held in flight, none overlapping');
      expect(b.maxActive, 1);
      final g = b.gate!;
      b.gate = null;
      g.complete();
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      expect(b.starts, 3, reason: 'exactly one trailing read');
      expect(b.maxActive, 1);
      await t.pumpWidget(gone);
    },
  );
  testWidgets('a failed read keeps the view and the next hint recovers', (
    t,
  ) async {
    final b = LiveBridge()..pending = 1;
    await openLive(t, b);
    expect(find.textContaining('1 message is waiting'), findsOneWidget);
    b.fail = true;
    b.pending = 2;
    b.hint();
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(find.textContaining('1 message is waiting'), findsOneWidget);
    b.fail = false;
    b.hint();
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(find.textContaining('2 messages are waiting'), findsOneWidget);
    await t.pumpWidget(gone);
  });
  testWidgets(
    'resume still reads once; disposed mid-read the late result is inert',
    (t) async {
      final b = LiveBridge();
      await openLive(t, b);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(b.checks, 2);
      b.gate = Completer<void>();
      b.hint();
      await t.pump();
      await t.pumpWidget(gone);
      expect(b.listeners, isEmpty);
      b.gate!.complete();
      await t.pump(const Duration(seconds: 3));
      expect(t.takeException(), isNull);
      final before = b.checks;
      b.hint();
      await t.pump(const Duration(seconds: 3));
      expect(b.checks, before, reason: 'no read after dispose');
    },
  );
}
