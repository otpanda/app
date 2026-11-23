import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge implements BrowserSessionBridge {
  @override
  String status = 'idle';
  int reads = 0, prompts = 0, logouts = 0;
  bool denied = false;
  int? clockNow;
  int lifetime = 60000;
  List<Map<String, Object>> sources = [], inbox = [];
  @override
  Future<void> get ready async {}
  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {
    prompts++;
    status = 'sign-in-required';
  }

  @override
  void clear() {
    status = 'idle';
  }

  @override
  void logout() {
    logouts++;
    status = 'idle';
  }

  @override
  Future<SessionResponse> read(String path) async {
    reads++;
    if (path.endsWith('/sources')) {
      return SessionResponse(200, jsonEncode({'sources': sources}));
    }
    if (path.endsWith('/unassigned')) {
      return SessionResponse(200, jsonEncode({'records': inbox}));
    }
    if (denied) {
      status = 'sign-in-required';
      return const SessionResponse(401, '{}');
    }
    return SessionResponse(
      200,
      jsonEncode(switch (path) {
        '/v1/manage/session' => {
          'ownerId': 'synthetic',
          'expiresAt':
              (clockNow ?? DateTime.now().millisecondsSinceEpoch) + lifetime,
        },
        '/v1/manage/entries' => {'entries': []},
        _ => {'records': []},
      }),
    );
  }
}

void main() {
  testWidgets('disabled connection is separate and does not launch auth', (
    t,
  ) async {
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: Bridge())));
    await t.pumpAndSettle();
    expect(find.textContaining('not enabled'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Sign in with passkey'),
          )
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'restored session loads once, refreshes once and clears honestly',
    (t) async {
      final b = Bridge()..status = 'restored';
      await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
      await t.pumpAndSettle();
      expect(b.reads, 5);
      await t.tap(find.text('Refresh real codes'));
      await t.pumpAndSettle();
      expect(b.reads, 10);
      await t.tap(find.text('Clear local access'));
      await t.pumpAndSettle();
      expect(find.textContaining('does not revoke'), findsOneWidget);
      expect(find.text('Browser session available.'), findsNothing);
    },
  );
  testWidgets('passkey cancellation has retry status and no code reads', (
    t,
  ) async {
    final b = Bridge()..status = 'passkey-ready';
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
    await t.pumpAndSettle();
    await t.tap(find.text('Use passkey'));
    await t.pumpAndSettle();
    expect(b.prompts, 1);
    expect(b.reads, 0);
    expect(find.textContaining('did not finish'), findsOneWidget);
  });
  testWidgets('401 stops real data load and updates status', (t) async {
    final b = Bridge()
      ..status = 'restored'
      ..denied = true;
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
    await t.pumpAndSettle();
    expect(b.reads, 1);
    expect(find.text('Browser session available.'), findsNothing);
  });
  testWidgets(
    'server signout distinct from local clear and disabled until enabled',
    (t) async {
      final b = Bridge()..status = 'restored';
      await t.pumpWidget(
        MaterialApp(home: BrowserAccountPage(bridge: b, loginEnabled: true)),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Sign out of this browser'));
      await t.pumpAndSettle();
      expect(b.logouts, 1);
      expect(b.status, 'idle');
      expect(find.text('Browser session available.'), findsNothing);
    },
  );
  Bridge privateBridge(int now) => Bridge()
    ..status = 'restored'
    ..clockNow = now
    ..sources = [
      {'source_id': 'phone', 'kind': 'sms', 'label': 'Personal phone'},
    ]
    ..inbox = [
      {
        'sourceId': 'phone',
        'eventId': 'event',
        'code': '654321',
        'receivedAt': now - 1000,
        'expiresAt': now + 3000,
      },
    ];

  testWidgets(
    'private code shows source and privacy, expires and timer disposes',
    (t) async {
      var clock = 100000;
      final b = privateBridge(clock);
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(bridge: b, clock: () => clock),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('654321'), findsOneWidget);
      expect(find.text('Personal phone'), findsOneWidget);
      expect(find.textContaining('Only you can see'), findsOneWidget);
      clock += 3000;
      await t.pump(const Duration(seconds: 1));
      expect(find.text('654321'), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('background, local clear and signout remove private code', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => t.binding.setSurfaceSize(null));
    for (final action in ['background', 'clear', 'signout']) {
      final b = privateBridge(100000);
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(
            key: UniqueKey(),
            bridge: b,
            clock: () => 100000,
            loginEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('654321'), findsOneWidget);
      if (action == 'background') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } else {
        await t.ensureVisible(
          find.text(
            action == 'clear'
                ? 'Clear local access'
                : 'Sign out of this browser',
          ),
        );
        await t.pumpAndSettle();
        await t.tap(
          find.text(
            action == 'clear'
                ? 'Clear local access'
                : 'Sign out of this browser',
          ),
        );
      }
      await t.pumpAndSettle();
      expect(find.text('654321'), findsNothing);
    }
  });
  testWidgets('copy rechecks expiry before clipboard write', (t) async {
    var clock = 100000;
    var copies = 0;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copies++;
        return null;
      },
    );
    final b = privateBridge(clock);
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(bridge: b, clock: () => clock),
      ),
    );
    await t.pumpAndSettle();
    final button = t.widget<IconButton>(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Copy private code',
      ),
    );
    button.onPressed!();
    await t.pump();
    expect(copies, 1);
    clock += 3000;
    button.onPressed!();
    await t.pump();
    expect(copies, 1);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  testWidgets('session expiry hides a still-live private code', (t) async {
    var clock = 100000;
    final b = privateBridge(clock)..lifetime = 1000;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(bridge: b, clock: () => clock),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('654321'), findsOneWidget);
    clock += 1000;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('654321'), findsNothing);
    expect(find.text('Browser access expired. Sign in again.'), findsOneWidget);
  });
}
