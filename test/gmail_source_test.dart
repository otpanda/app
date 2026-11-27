import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/gmail_source.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge implements GmailSourceBridge {
  bool ready = false, passkey = false;
  bool blocked = false;
  int connects = 0, checks = 0, pending = 0, skipped = 0, leftover = 0;
  GmailDisconnectResult result = const GmailDisconnectResult(
    disconnected: true,
  );
  int disconnects = 0;
  @override
  Future<SessionResponse> gmailSourceStatus() async {
    checks++;
    return SessionResponse(
      200,
      jsonEncode({
        'ready': ready,
        'passkeyRequired': passkey,
        'pending': pending,
        'skipped': {'too_large': skipped},
        'lifecycleBlocked': blocked,
        'leftoverLabels': leftover,
        'leftoverFilters': leftover,
      }),
    );
  }

  String returned = '';
  @override
  Future<String> takeGmailResult() async {
    final r = returned;
    returned = '';
    return r;
  }

  @override
  Future<void> connectGmail() async {
    connects++;
  }

  @override
  Future<GmailDisconnectResult> disconnectGmail(
    String id, {
    String rules = 'keep',
  }) async {
    disconnects++;
    return result;
  }
}

void main() {
  testWidgets('pending and skipped status uses singular and plural grammar', (
    t,
  ) async {
    final b = Bridge()
      ..pending = 1
      ..skipped = 1;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GmailSourceConnect(bridge: b)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('1 message is waiting'), findsOneWidget);
    expect(
      find.textContaining('1 message in the last 8 days was not collected'),
      findsOneWidget,
    );
    b.pending = 2;
    b.skipped = 2;
    expect(b.checks, 1, reason: 'no timer read');
    await t.pump(const Duration(seconds: 95));
    expect(b.checks, 1, reason: 'still no timer read');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.textContaining('2 messages are waiting'), findsOneWidget);
    expect(
      find.textContaining('2 messages in the last 8 days were not collected'),
      findsOneWidget,
    );
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  testWidgets(
    'source status refreshes automatically while mounted and stops after dispose',
    (t) async {
      final b = Bridge();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GmailSourceConnect(bridge: b)),
        ),
      );
      await t.pumpAndSettle();
      expect(b.checks, 1);
      await t.pump(const Duration(seconds: 95));
      expect(b.checks, 1, reason: 'no timer read');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(b.checks, 2);
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump(const Duration(seconds: 31));
      expect(b.checks, 2, reason: 'nothing after dispose');
    },
  );

  testWidgets('unavailable collection has no misleading connect button', (
    t,
  ) async {
    final b = Bridge();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GmailSourceConnect(bridge: b)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Email collection is not available yet.'), findsOneWidget);
    expect(find.text('Connect Gmail'), findsNothing);
    expect(b.connects, 0);
  });
  testWidgets('connection requires disclosure and explicit confirmation', (
    t,
  ) async {
    final b = Bridge()..ready = true;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GmailSourceConnect(bridge: b)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Connect Gmail'));
    await t.pumpAndSettle();
    expect(
      find.textContaining('manage labels and manage basic Gmail settings'),
      findsOneWidget,
    );
    expect(b.connects, 0);
    await t.tap(find.text('Not now'));
    await t.pumpAndSettle();
    expect(b.connects, 0);
    await t.tap(find.text('Connect Gmail'));
    await t.pumpAndSettle();
    await t.tap(find.text('Verify and continue'));
    await t.pumpAndSettle();
    expect(b.connects, 1);
  });
  testWidgets('missing passkey routes account not google', (t) async {
    final b = Bridge()
      ..ready = true
      ..passkey = true;
    var opened = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GmailSourceConnect(
            bridge: b,
            onOpenAccount: () => opened = true,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Account & security'));
    expect(opened, true);
    expect(b.connects, 0);
  });
  testWidgets(
    'disconnect discloses retained Google grant and needs confirmation',
    (t) async {
      final b = Bridge();
      var changed = false;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GmailSourceDisconnect(
              bridge: b,
              sourceId: 'source',
              label: 'test@example.test',
              onChanged: () => changed = true,
            ),
          ),
        ),
      );
      await t.tap(find.text('Disconnect Gmail'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('Google permission to read mail and manage'),
        findsOneWidget,
      );
      expect(changed, false);
      await t.tap(find.text('Keep connected'));
      await t.pumpAndSettle();
      expect(changed, false);
      await t.tap(find.text('Disconnect Gmail'));
      await t.pumpAndSettle();
      await t.tap(find.text('Verify and disconnect'));
      await t.pumpAndSettle();
      expect(find.text('Delete saved matching rules?'), findsOneWidget);
      await t.tap(find.text('Keep paused'));
      await t.pumpAndSettle();
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(changed, true);
    },
  );

  Widget host(Widget w) => MaterialApp(home: Scaffold(body: w));

  testWidgets(
    'lifecycleBlocked pauses connect with a truthful durable notice',
    (t) async {
      final b = Bridge()
        ..ready = true
        ..blocked = true;
      await t.pumpWidget(host(GmailSourceConnect(bridge: b)));
      await t.pumpAndSettle();
      expect(find.text('Connecting Gmail is paused.'), findsOneWidget);
      expect(find.textContaining('does not clear by itself'), findsOneWidget);
      expect(find.textContaining('will not retry it for you'), findsOneWidget);
      expect(find.textContaining('retries automatically'), findsNothing);
      final button = t.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(b.connects, 0);
      // The notice follows the server and never times out on the client.
      await t.pump(const Duration(minutes: 10));
      expect(find.text('Connecting Gmail is paused.'), findsOneWidget);
      // A later status that no longer reports the blocker re-enables connect.
      b.blocked = false;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.text('Connecting Gmail is paused.'), findsNothing);
      expect(
        t.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
    },
  );

  testWidgets('leftover labels and filters use singular and plural wording', (
    t,
  ) async {
    final b = Bridge()
      ..ready = true
      ..leftover = 1;
    await t.pumpWidget(host(GmailSourceConnect(bridge: b)));
    await t.pumpAndSettle();
    expect(
      find.textContaining('1 OTPanda label and 1 filter may remain'),
      findsOneWidget,
    );
    b.leftover = 2;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(
      find.textContaining('2 OTPanda labels and 2 filters may remain'),
      findsOneWidget,
    );
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
  });

  Future<void> runDisconnect(
    WidgetTester t,
    Bridge b,
    void Function() changed,
  ) async {
    await t.pumpWidget(
      host(
        GmailSourceDisconnect(
          bridge: b,
          sourceId: 'source',
          label: 'test@example.test',
          onChanged: changed,
        ),
      ),
    );
    await t.tap(find.text('Disconnect Gmail'));
    await t.pumpAndSettle();
    await t.tap(find.text('Verify and disconnect'));
    await t.pumpAndSettle();
    await t.tap(find.text('Keep paused'));
    await t.pumpAndSettle();
  }

  testWidgets(
    'disconnect that removed artifacts says so and keeps the Google grant notice',
    (t) async {
      final b = Bridge()
        ..result = const GmailDisconnectResult(
          disconnected: true,
          artifactsRemoved: true,
        );
      var changed = 0;
      await runDisconnect(t, b, () => changed++);
      expect(find.text('Gmail disconnected'), findsOneWidget);
      expect(
        find.textContaining('removed the label and filter it created'),
        findsOneWidget,
      );
      expect(find.textContaining('may still list OTPanda'), findsOneWidget);
      expect(changed, 0);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(changed, 1);
    },
  );

  testWidgets(
    'disconnect with unresolved lifecycle never claims artifact removal',
    (t) async {
      final b = Bridge()
        ..result = const GmailDisconnectResult(
          disconnected: true,
          lifecycleBlocked: true,
        );
      var changed = 0;
      await runDisconnect(t, b, () => changed++);
      expect(find.text('Gmail disconnected'), findsOneWidget);
      expect(
        find.textContaining(
          'could not confirm whether its label and filter were removed',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('also removed'), findsNothing);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(changed, 1);
    },
  );

  testWidgets('disconnect where artifact removal failed says they may remain', (
    t,
  ) async {
    final b = Bridge()
      ..result = const GmailDisconnectResult(
        disconnected: true,
        artifactsRemoved: false,
      );
    await runDisconnect(t, b, () {});
    expect(
      find.textContaining('could not remove the label and filter'),
      findsOneWidget,
    );
  });

  testWidgets(
    'disconnect blocked by an in-flight step changes nothing and keeps the source',
    (t) async {
      final b = Bridge()
        ..result = const GmailDisconnectResult(
          disconnected: false,
          lifecycleBlocked: true,
        );
      var changed = 0;
      await runDisconnect(t, b, () => changed++);
      expect(find.text('Nothing was changed'), findsOneWidget);
      expect(
        find.textContaining('cannot confirm whether collection'),
        findsOneWidget,
      );
      expect(find.textContaining('Collection continues'), findsNothing);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(changed, 0);
      expect(find.text('Disconnect Gmail'), findsOneWidget);
    },
  );

  test(
    'disconnect result parsing keeps only booleans and rejects bad bodies',
    () {
      final r = GmailDisconnectResult.fromJson(
        '{"disconnected":true,"googlePermissionRemains":true,"artifactsRemoved":"yes","x":1}',
      );
      expect(r.artifactsRemoved, isNull);
      expect(r.lifecycleBlocked, false);
      expect(() => GmailDisconnectResult.fromJson('{}'), throwsFormatException);
      expect(() => GmailDisconnectResult.fromJson('[]'), throwsFormatException);
    },
  );

  Widget card(Bridge b, {bool source = false}) => MaterialApp(
    home: Scaffold(
      body: GmailSourceConnect(bridge: b, hasGmailSource: source),
    ),
  );
  const connectedText = 'Gmail connected.';
  testWidgets(
    'connected marker shows success only with ready status and a listed Gmail source',
    (t) async {
      final b = Bridge()
        ..ready = true
        ..returned = 'connected';
      await t.pumpWidget(card(b, source: true));
      await t.pumpAndSettle();
      expect(find.text(connectedText), findsOneWidget);
      expect(b.checks, greaterThan(0));
      expect(b.returned, '');
    },
  );
  testWidgets('spoofed connected marker with not-ready status shows nothing', (
    t,
  ) async {
    final b = Bridge()
      ..ready = false
      ..returned = 'connected';
    await t.pumpWidget(card(b, source: true));
    await t.pumpAndSettle();
    expect(find.text(connectedText), findsNothing);
    expect(find.text('Email collection is not available yet.'), findsOneWidget);
  });
  testWidgets('spoofed connected marker with no Gmail source shows nothing', (
    t,
  ) async {
    final b = Bridge()
      ..ready = true
      ..returned = 'connected';
    await t.pumpWidget(card(b));
    await t.pumpAndSettle();
    expect(find.text(connectedText), findsNothing);
    expect(find.text('Connect Gmail'), findsOneWidget);
  });
  testWidgets(
    'claim waits for the source list, then is cleared when the source disappears',
    (t) async {
      final b = Bridge()
        ..ready = true
        ..returned = 'connected';
      await t.pumpWidget(card(b));
      await t.pumpAndSettle();
      expect(find.text(connectedText), findsNothing);
      await t.pumpWidget(card(b, source: true));
      await t.pumpAndSettle();
      expect(find.text(connectedText), findsOneWidget);
      await t.pumpWidget(card(b));
      await t.pumpAndSettle();
      expect(find.text(connectedText), findsNothing);
      await t.pumpWidget(card(b, source: true));
      await t.pumpAndSettle();
      expect(find.text(connectedText), findsNothing);
    },
  );
  testWidgets('refused return shows one neutral message with no reason', (
    t,
  ) async {
    final b = Bridge()
      ..ready = true
      ..returned = 'refused';
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GmailSourceConnect(bridge: b)),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.text('Gmail was not connected. Try again when you are ready.'),
      findsOneWidget,
    );
    expect(find.text(connectedText), findsNothing);
    expect(find.textContaining('test@example.test'), findsNothing);
    expect(find.textContaining('dev_mailbox_refused'), findsNothing);
  });
  testWidgets('no return marker leaves the default card unchanged', (t) async {
    final b = Bridge()..ready = true;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GmailSourceConnect(bridge: b)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text(connectedText), findsNothing);
    expect(find.textContaining('was not connected'), findsNothing);
    expect(find.text('Connect Gmail'), findsOneWidget);
  });
}
