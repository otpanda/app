import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge implements BrowserSessionBridge, SessionViewBridge {
  @override
  int restoredView = 0;
  @override
  void setView(int view) {
    restoredView = view;
  }

  @override
  String status = 'idle';
  int reads = 0, prompts = 0, logouts = 0;
  bool denied = false;
  int? clockNow;
  int lifetime = 60000;
  int copyReceipts = 0, organizationWrites = 0, organizationReads = 0;
  Completer<SessionResponse>? pendingReceipt, pendingSession;
  bool conflict = false, organizationDenied = false;
  Map<String, dynamic> cloud = {
    'revision': 0,
    'tags': [],
    'entries': [],
    'ranking': [],
  };
  List<Map<String, Object>> sources = [], inbox = [];
  List<Map<String, Object>> entries = [], codes = [];
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
  Future<SessionResponse> organize(String method, String body) async {
    if (organizationDenied) return const SessionResponse(401, '{}');
    if (method == 'GET') organizationReads++;
    if (method == 'PUT') {
      if (conflict) return const SessionResponse(409, '{}');
      final data = jsonDecode(body) as Map<String, dynamic>;
      organizationWrites++;
      cloud = {
        ...(data['document'] as Map<String, dynamic>),
        'revision': (cloud['revision'] as int) + 1,
        'ranking': cloud['ranking'],
      };
    }
    return SessionResponse(200, jsonEncode(cloud));
  }

  @override
  Future<SessionResponse> copied(String entryId, int createdAt) async {
    copyReceipts++;
    if (pendingReceipt != null) return pendingReceipt!.future;
    return const SessionResponse(200, '{"accepted":true}');
  }

  @override
  Future<SessionResponse> read(String path) async {
    reads++;
    if (path == '/v1/manage/session' && pendingSession != null) {
      return pendingSession!.future;
    }
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
        '/v1/manage/entries' => {'entries': entries},
        '/v1/manage/active-codes' => {'records': codes},
        _ => {'records': []},
      }),
    );
  }
}

void main() {
  testWidgets('account restore opens account without storing account content', (
    t,
  ) async {
    final bridge = Bridge()
      ..status = 'restored'
      ..restoredView = 4;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: bridge,
          accountOnly: true,
          workspaceEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Your account'), findsWidgets);
    await t.tap(find.byTooltip('Back to codes'));
    await t.pumpAndSettle();
    expect(bridge.restoredView, 0);
    expect(find.text('Your codes'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    expect(t.takeException(), isNull);
  });

  testWidgets('account-only accepts server session with lagging client clock', (
    t,
  ) async {
    final b = Bridge()
      ..status = 'restored'
      ..clockNow = 500000;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          loginEnabled: true,
          clock: () => 100000,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Temporary diagnostics'), findsOneWidget);
    expect(b.reads, 2);
    expect(b.organizationReads, 0);
  });
  testWidgets(
    'account-only pause invalidates refresh without stuck busy or late verified state',
    (t) async {
      final b = Bridge()
        ..status = 'restored'
        ..clockNow = 100000;
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(
            bridge: b,
            accountOnly: true,
            loginEnabled: true,
            clock: () => 100000,
          ),
        ),
      );
      await t.pumpAndSettle();
      b.pendingSession = Completer<SessionResponse>();
      if (find.text('Temporary diagnostics').evaluate().isNotEmpty &&
          find.text('Check account session').evaluate().isEmpty) {
        await t.tap(find.text('Temporary diagnostics'));
        await t.pumpAndSettle();
      }
      await t.tap(find.text('Check account session'));
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      b.pendingSession!.complete(
        const SessionResponse(
          200,
          '{"ownerId":"synthetic","expiresAt":160000}',
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Account session verified.'), findsNothing);
      if (find.text('Check account session').evaluate().isEmpty) {
        await t.tap(find.text('Temporary diagnostics'));
        await t.pumpAndSettle();
      }
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Check account session'),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Sign out of this browser'),
            )
            .onPressed,
        isNotNull,
      );
      b.pendingSession = null;
      if (find.text('Temporary diagnostics').evaluate().isNotEmpty &&
          find.text('Check account session').evaluate().isEmpty) {
        await t.tap(find.text('Temporary diagnostics'));
        await t.pumpAndSettle();
      }
      await t.tap(find.text('Check account session'));
      await t.pumpAndSettle();
      expect(find.text('Temporary diagnostics'), findsOneWidget);
      expect(b.organizationReads, 0);
    },
  );
  testWidgets('account-only reads session and never data or organization', (
    t,
  ) async {
    final b = Bridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          loginEnabled: true,
          clock: () => 100000,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(b.reads, 2);
    expect(b.organizationReads, 0);
    expect(find.text('Temporary diagnostics'), findsOneWidget);
    expect(find.text('No active codes in selected entries.'), findsNothing);
    expect(find.text('Refresh real codes'), findsNothing);
    if (find.text('Temporary diagnostics').evaluate().isNotEmpty &&
        find.text('Check account session').evaluate().isEmpty) {
      await t.tap(find.text('Temporary diagnostics'));
      await t.pumpAndSettle();
    }
    await t.tap(find.text('Check account session'));
    await t.pumpAndSettle();
    expect(b.reads, 4);
    expect(b.organizationReads, 0);
  });
  testWidgets('account-only expiry clears verified state', (t) async {
    var now = 100000;
    final b = Bridge()
      ..status = 'restored'
      ..clockNow = now
      ..lifetime = 1000;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          loginEnabled: true,
          clock: () => now,
        ),
      ),
    );
    await t.pumpAndSettle();
    now += 1001;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Browser access expired. Sign in again.'), findsOneWidget);
    expect(find.text('Account session verified.'), findsNothing);
    expect(b.organizationReads, 0);
  });
  testWidgets(
    'account-only denied read never presents verified or empty code success',
    (t) async {
      final b = Bridge()
        ..status = 'restored'
        ..denied = true;
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(
            bridge: b,
            accountOnly: true,
            loginEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(b.reads, 1);
      expect(b.organizationReads, 0);
      expect(find.text('Account session verified.'), findsNothing);
      expect(find.text('No active codes in selected entries.'), findsNothing);
    },
  );
  testWidgets('signup ready uses explicit create label and manual prompt', (
    t,
  ) async {
    final b = Bridge()..status = 'signup-ready';
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
    await t.pumpAndSettle();
    expect(find.text('Create passkey'), findsOneWidget);
    expect(b.prompts, 0);
    await t.tap(find.text('Create passkey'));
    await t.pumpAndSettle();
    expect(b.prompts, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('clock and retry guidance remains readable at phone width', (
    t,
  ) async {
    t.view.physicalSize = const Size(360, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    for (final status in ['check-clock-or-restart', 'signup-retry-required']) {
      final b = Bridge()..status = status;
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(key: ValueKey(status), bridge: b),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(
        find.textContaining(
          status == 'check-clock-or-restart'
              ? 'Check your device date'
              : 'Passkey setup did not finish',
        ),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('disabled connection is separate and does not launch auth', (
    t,
  ) async {
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: Bridge())));
    await t.pumpAndSettle();
    expect(find.textContaining('not enabled'), findsNothing);
    expect(find.textContaining('not available in this stage'), findsNothing);
    expect(find.text('No active browser access.'), findsOneWidget);
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
  testWidgets(
    'focus retains valid codes; local clear and signout remove them',
    (t) async {
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
        expect(
          find.text('654321'),
          action == 'background' ? findsOneWidget : findsNothing,
        );
      }
    },
  );
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
  testWidgets(
    'authorized assigned code shows shared boundary and expires before copy',
    (t) async {
      var clock = 100000;
      var copied = '';
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      final b = privateBridge(clock)
        ..entries = [
          {
            'entry_id': 'shared',
            'service_name': 'Shared service',
            'account_name': 'viewer',
            'capabilities': {'manage': false},
          },
        ]
        ..codes = [
          {
            'entryId': 'shared',
            'code': '123456',
            'receivedAt': clock - 1000,
            'expiresAt': clock + 2000,
          },
        ];
      await t.binding.setSurfaceSize(const Size(800, 1100));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(bridge: b, clock: () => clock),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('123456'), findsOneWidget);
      expect(find.textContaining('Read-only · Source hidden'), findsOneWidget);
      expect(
        t.getTopLeft(find.text('654321')).dy,
        lessThan(t.getTopLeft(find.text('123456')).dy),
      );
      final button = t.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Copy entry code',
        ),
      );
      button.onPressed!();
      await t.pump();
      expect(copied, '123456');
      expect(b.copyReceipts, 1);
      copied = '';
      clock += 2000;
      button.onPressed!();
      await t.pump(const Duration(seconds: 1));
      expect(copied, '');
      expect(b.copyReceipts, 1);
      expect(find.text('123456'), findsNothing);
      expect(find.text('Shared service'), findsOneWidget);
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );
  testWidgets(
    'cloud organization restores private tags pins and automatic recent ranking without controls',
    (t) async {
      await t.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final b = Bridge()
        ..status = 'restored'
        ..clockNow = 100000
        ..entries = [
          {
            'entry_id': 'first',
            'service_name': 'First',
            'capabilities': {'manage': true},
          },
          {
            'entry_id': 'second',
            'service_name': 'Second',
            'capabilities': {'manage': false},
          },
        ]
        ..cloud = {
          'revision': 4,
          'tags': [
            {'id': 'tag', 'label': 'Work'},
          ],
          'entries': [
            {
              'entryId': 'first',
              'pinned': false,
              'tagIds': ['tag'],
            },
            {'entryId': 'second', 'pinned': true, 'tagIds': []},
          ],
          'ranking': [
            {'entryId': 'first', 'score': 5},
          ],
        };
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(bridge: b, clock: () => 100000),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Reset copy counts'), findsNothing);
      expect(find.textContaining('confirmed copies'), findsNothing);
      expect(find.textContaining('Sort:'), findsNothing);
      expect(
        find.text(
          'Private cloud organization. Recent successful copies help order your unpinned entries automatically.',
        ),
        findsOneWidget,
      );
      expect(
        t.getTopLeft(find.text('Second')).dy,
        lessThan(t.getTopLeft(find.text('First')).dy),
      );
      await t.tap(find.byTooltip('Unpin Second'));
      await t.pumpAndSettle();
      expect(b.organizationWrites, 1);
      expect(
        t.getTopLeft(find.text('First')).dy,
        lessThan(t.getTopLeft(find.text('Second')).dy),
      );
      await t.tap(find.text('Clear local access'));
      await t.pumpAndSettle();
      expect(find.text('Work'), findsNothing);
    },
  );
  testWidgets('clipboard failure never submits a ranking receipt', (t) async {
    final b = privateBridge(100000)
      ..entries = [
        {
          'entry_id': 'e',
          'service_name': 'Example',
          'capabilities': {'manage': true},
        },
      ]
      ..codes = [
        {
          'entryId': 'e',
          'code': '112233',
          'receivedAt': 99000,
          'expiresAt': 110000,
        },
      ];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'denied');
        }
        return null;
      },
    );
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(bridge: b, clock: () => 100000),
      ),
    );
    await t.pumpAndSettle();
    final button = t.widget<IconButton>(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Copy entry code',
      ),
    );
    button.onPressed!();
    await t.pumpAndSettle();
    expect(b.copyReceipts, 0);
    expect(find.text('Could not copy code.'), findsOneWidget);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  testWidgets('late copy receipt after clear cannot reload cloud state', (
    t,
  ) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final pending = Completer<SessionResponse>();
    final b = privateBridge(100000)
      ..pendingReceipt = pending
      ..entries = [
        {
          'entry_id': 'e',
          'service_name': 'Example',
          'capabilities': {'manage': true},
        },
      ]
      ..codes = [
        {
          'entryId': 'e',
          'code': '112233',
          'receivedAt': 99000,
          'expiresAt': 110000,
        },
      ];
    await t.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(bridge: b, clock: () => 100000),
      ),
    );
    await t.pumpAndSettle();
    final before = b.organizationReads;
    final button = t.widget<IconButton>(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Copy entry code',
      ),
    );
    button.onPressed!();
    await t.pump();
    expect(b.copyReceipts, 1);
    await t.tap(find.text('Clear local access'));
    await t.pumpAndSettle();
    pending.complete(const SessionResponse(200, '{"accepted":true}'));
    await t.pumpAndSettle();
    expect(b.organizationReads, before);
    expect(find.text('Organize your entries'), findsNothing);
  });
  testWidgets('organization401 clears codes and cloud editor', (t) async {
    final b = privateBridge(100000)..organizationDenied = true;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(bridge: b, clock: () => 100000),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('654321'), findsNothing);
    expect(find.text('Organize your entries'), findsNothing);
  });
  testWidgets(
    'stale cloud edit reports conflict and restores server preferences',
    (t) async {
      await t.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final b = Bridge()
        ..status = 'restored'
        ..clockNow = 100000
        ..conflict = true
        ..entries = [
          {
            'entry_id': 'e',
            'service_name': 'Example',
            'capabilities': {'manage': true},
          },
        ]
        ..cloud = {
          'revision': 2,
          'tags': [],
          'entries': [
            {'entryId': 'e', 'pinned': false, 'tagIds': []},
          ],
          'ranking': [],
        };
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(bridge: b, clock: () => 100000),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Pin Example'));
      await t.pumpAndSettle();
      expect(find.byTooltip('Pin Example'), findsOneWidget);
      expect(find.byTooltip('Unpin Example'), findsNothing);
      expect(find.textContaining('Organization was not saved'), findsOneWidget);
    },
  );
}
