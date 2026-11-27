import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/extension_connect.dart';
import 'package:otpanda_client/session_contract.dart';

class Bridge
    implements
        BrowserSessionBridge,
        SessionViewBridge,
        RealtimeBridge,
        EntryManagementBridge {
  @override
  Future<void> renameEntry(String id, String label) async {}
  @override
  Future<void> updateAccount(String id, String? account) async {}
  void Function(String)? contentHint;
  @override
  void Function() realtimeSubscribe(void Function(String) listener) {
    contentHint = listener;
    return () => contentHint = null;
  }

  @override
  int restoredView = 0;
  @override
  void setView(int view) {
    restoredView = view;
  }

  @override
  String status = 'idle';
  final readPaths = <String>[];
  int reads = 0, prompts = 0, logouts = 0;
  bool denied = false;
  int? clockNow;
  int lifetime = 60000;
  int copyReceipts = 0, organizationWrites = 0, organizationReads = 0;
  Completer<SessionResponse>? pendingReceipt, pendingSession;
  bool conflict = false, organizationDenied = false, organizationThrows = false;
  int attemptedOrganizationWrites = 0;
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
      attemptedOrganizationWrites++;
      if (organizationThrows) throw StateError('lost response after dispatch');
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
    readPaths.add(path);
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

class ExtensionBridge extends Bridge implements ExtensionConnectBridge {
  @override
  String extensionIntent = 'chrome';
  int connects = 0, cancels = 0;
  String reason = '';
  @override
  Future<String> connectExtension() async {
    connects++;
    return reason;
  }

  @override
  void cancelExtension() {
    cancels++;
    extensionIntent = '';
  }
}

Future<void> signOut(WidgetTester t) async {
  await t.tap(find.byTooltip('Account & security'));
  await t.pumpAndSettle();
  await t.scrollUntilVisible(
    find.byKey(const Key('browser-sign-out')),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await t.ensureVisible(find.byKey(const Key('browser-sign-out')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('browser-sign-out')));
}

double readingOrder(WidgetTester t, Finder f) {
  final p = t.getTopLeft(f);
  return p.dy * 10000 + p.dx;
}

void main() {
  for (final fails in [false, true]) {
    testWidgets(
      'dispatched cloud tag PUT with lost response stays unknown and cannot resend',
      (t) async {
        final b = Bridge()
          ..status = 'restored'
          ..clockNow = 100000
          ..organizationThrows = true
          ..entries = [
            {
              'entry_id': 'a',
              'service_name': 'Account',
              'capabilities': {'manage': true},
            },
          ]
          ..cloud = {
            'revision': 0,
            'tags': [
              {'id': 'work', 'label': 'Work'},
            ],
            'entries': [
              {
                'entryId': 'a',
                'pinned': false,
                'tagIds': ['work'],
              },
            ],
            'ranking': [],
          };
        await t.pumpWidget(
          MaterialApp(
            home: BrowserAccountPage(
              bridge: b,
              accountOnly: true,
              workspaceEnabled: true,
              entryEditEnabled: true,
              clock: () => 100000,
              navigation: 'accounts/YQ',
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('entry-edit')));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Remove Work'));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('entry-save')));
        await t.pumpAndSettle();
        expect(find.textContaining('Could not confirm tags.'), findsWidgets);
        expect(find.textContaining('Tags were not saved.'), findsNothing);
        expect(b.attemptedOrganizationWrites, 1);
        expect(
          t.widget<FilledButton>(find.byKey(const Key('entry-save'))).onPressed,
          isNull,
        );
        await t.pump(const Duration(seconds: 2));
        expect(b.attemptedOrganizationWrites, 1);
      },
    );
    testWidgets(
      'real Details bottom Save awaits cloud organization persistence failure=$fails',
      (t) async {
        final b = Bridge()
          ..status = 'restored'
          ..clockNow = 100000
          ..conflict = fails
          ..entries = [
            {
              'entry_id': 'a',
              'service_name': 'Account',
              'capabilities': {'manage': true},
            },
          ]
          ..cloud = {
            'revision': 0,
            'tags': [
              {'id': 'work', 'label': 'Work'},
            ],
            'entries': [
              {
                'entryId': 'a',
                'pinned': false,
                'tagIds': ['work'],
              },
            ],
            'ranking': [],
          };
        await t.pumpWidget(
          MaterialApp(
            home: BrowserAccountPage(
              bridge: b,
              accountOnly: true,
              workspaceEnabled: true,
              entryEditEnabled: true,
              clock: () => 100000,
              navigation: 'accounts/YQ',
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('entry-edit')));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Remove Work'));
        await t.pumpAndSettle();
        expect(b.organizationWrites, 0);
        await t.tap(find.byKey(const Key('entry-save')));
        await t.pumpAndSettle();
        if (fails) {
          expect(find.textContaining('Tags were not saved.'), findsOneWidget);
          expect(b.organizationWrites, 0);
          expect((b.cloud['entries'] as List).single['tagIds'], ['work']);
        } else {
          expect(b.organizationWrites, 1);
          expect((b.cloud['entries'] as List).single['tagIds'], isEmpty);
        }
      },
    );
  }
  testWidgets('a pending extension intent needs one explicit Connect press', (
    t,
  ) async {
    final b = ExtensionBridge()
      ..status = 'restored'
      ..reason = 'retry';
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Connect browser extension?'), findsOneWidget);
    expect(b.connects, 0, reason: 'showing the dialog never calls begin');
    await t.tap(find.byKey(const Key('extension-connect-confirm')));
    await t.pumpAndSettle();
    expect(b.connects, 1);
    expect(find.byKey(const Key('extension-connect-message')), findsOneWidget);
    await t.tap(find.byKey(const Key('extension-connect-cancel')));
    await t.pumpAndSettle();
    expect(b.cancels, 1);
    expect(b.connects, 1);
    expect(find.text('Connect browser extension?'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    expect(t.takeException(), isNull);
  });
  testWidgets('no extension intent shows no dialog', (t) async {
    final b = ExtensionBridge()
      ..status = 'restored'
      ..extensionIntent = '';
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Connect browser extension?'), findsNothing);
    expect(b.connects, 0);
  });
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
          navigation: 'settings',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Temporary diagnostics'), findsNothing);
    await t.tap(find.byTooltip('Back to codes'));
    await t.pumpAndSettle();
    expect(bridge.restoredView, 4); // obsolete view slot is no longer written
    expect(find.byKey(const Key('product-top-bar')), findsOneWidget);
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
    expect(find.text('Temporary diagnostics'), findsNothing);
    expect(find.text('Account & security'), findsWidgets);
    expect(b.reads, 2);
    expect(b.organizationReads, 0);
  });
  testWidgets(
    'account-only pause invalidates a pending read without stuck busy or late verified state',
    (t) async {
      final b = Bridge()
        ..status = 'restored'
        ..clockNow = 100000
        ..pendingSession = Completer<SessionResponse>();
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
      b.pendingSession = null;
      await t.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Temporary diagnostics'), findsNothing);
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
    expect(find.text('Temporary diagnostics'), findsNothing);
    expect(find.text('No active codes in selected entries.'), findsNothing);
    expect(find.text('Refresh real codes'), findsNothing);
    expect(b.reads, 2);
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
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
          navigation: 'codes',
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Create my passkey'), findsOneWidget);
    expect(b.prompts, 0);
    await t.tap(find.text('Create my passkey'));
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
              : 'Sign-in did not finish',
        ),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
    }
  });

  testWidgets('disabled connection is separate and does not launch auth', (
    t,
  ) async {
    final b = Bridge();
    await t.pumpWidget(MaterialApp(home: BrowserAccountPage(bridge: b)));
    await t.pumpAndSettle();
    expect(find.textContaining('not enabled'), findsNothing);
    expect(find.textContaining('not available in this stage'), findsNothing);
    expect(
      find.text(
        'Your codes, wherever you need them. Sign in or get started below.',
      ),
      findsOneWidget,
    );
    expect(
      t
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Sign in with a passkey'),
          )
          .onPressed,
      isNotNull,
    );
    expect(b.prompts, 0);
    expect(b.reads, 0);
  });
  testWidgets(
    'restored workspace reads once, realtime hint refreshes and server signout clears',
    (t) async {
      var clock = 100000;
      final b = Bridge()
        ..status = 'restored'
        ..clockNow = clock;
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(
            bridge: b,
            clock: () => clock,
            accountOnly: true,
            workspaceEnabled: true,
            navigation: 'codes',
            loginEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        b.readPaths.where((p) => p == '/v1/manage/active-codes').length,
        1,
      );
      expect(find.text('Refresh real codes'), findsNothing);
      clock += 31000;
      await t.pump(const Duration(seconds: 1));
      expect(b.contentHint, isNotNull);
      b.contentHint!.call('changed');
      await t.pump(const Duration(seconds: 1));
      await t.pumpAndSettle();
      expect(
        b.readPaths.where((p) => p == '/v1/manage/active-codes').length,
        2,
      );
      await signOut(t);
      await t.pumpAndSettle();
      expect(b.logouts, 1);
      expect(find.text('Clear local access'), findsNothing);
      expect(find.text('Browser session available.'), findsNothing);
    },
  );
  testWidgets('passkey cancellation has retry status and no code reads', (
    t,
  ) async {
    final b = Bridge()..status = 'passkey-ready';
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
          navigation: 'codes',
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Continue with passkey'));
    await t.pumpAndSettle();
    expect(b.prompts, 1);
    expect(b.reads, 0);
    expect(find.textContaining('Sign in'), findsWidgets);
  });
  testWidgets('401 stops real data load and updates status', (t) async {
    final b = Bridge()
      ..status = 'restored'
      ..denied = true;
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
          navigation: 'codes',
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(b.reads, 1);
    expect(find.text('Browser session available.'), findsNothing);
  });
  testWidgets('server signout is the only visible exit action', (t) async {
    final b = Bridge()..status = 'restored';
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
          navigation: 'codes',
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    await signOut(t);
    await t.pumpAndSettle();
    expect(b.logouts, 1);
    expect(b.status, 'idle');
    expect(find.text('Browser session available.'), findsNothing);
  });
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
          home: BrowserAccountPage(
            bridge: b,
            clock: () => clock,
            accountOnly: true,
            workspaceEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('654 321'), findsOneWidget);
      expect(find.text('Only you'), findsOneWidget);
      await t.tap(find.byTooltip('Details'));
      await t.pumpAndSettle();
      expect(find.text('Personal phone'), findsOneWidget);
      await t.tap(find.byTooltip('Back to codes'));
      await t.pumpAndSettle();
      clock += 3000;
      await t.pump(const Duration(seconds: 1));
      expect(find.text('654 321'), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 2));
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('focus retains valid codes and signout removes them', (t) async {
    await t.binding.setSurfaceSize(const Size(800, 1100));
    addTearDown(() => t.binding.setSurfaceSize(null));
    for (final action in ['background', 'signout']) {
      final b = privateBridge(100000);
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(
            key: UniqueKey(),
            bridge: b,
            clock: () => 100000,
            accountOnly: true,
            workspaceEnabled: true,
            loginEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('654 321'), findsOneWidget);
      if (action == 'background') {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await t.pump();
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } else {
        await signOut(t);
      }
      await t.pumpAndSettle();
      expect(
        find.text('654 321'),
        action == 'background' ? findsOneWidget : findsNothing,
      );
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
        home: BrowserAccountPage(
          bridge: b,
          clock: () => clock,
          accountOnly: true,
          workspaceEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    final button = t.widget<IconButton>(
      find.byKey(const ValueKey('copy-button-private/phone/event')),
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
        home: BrowserAccountPage(
          bridge: b,
          clock: () => clock,
          accountOnly: true,
          workspaceEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('654 321'), findsOneWidget);
    clock += 1000;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('654 321'), findsNothing);
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
          home: BrowserAccountPage(
            bridge: b,
            clock: () => clock,
            accountOnly: true,
            workspaceEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('123 456'), findsOneWidget);
      expect(find.text('viewer'), findsWidgets);
      expect(find.text('Only you'), findsOneWidget);
      expect(
        find.text('Personal phone'),
        findsNothing,
      ); // source only in private Details
      final button = t.widget<IconButton>(
        find.byKey(const ValueKey('copy-button-entry/shared/99000')),
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
      expect(find.text('123 456'), findsNothing);
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
          home: BrowserAccountPage(
            bridge: b,
            clock: () => 100000,
            accountOnly: true,
            workspaceEnabled: true,
            loginEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Reset copy counts'), findsNothing);
      expect(find.textContaining('confirmed copies'), findsNothing);
      expect(find.textContaining('Sort:'), findsNothing);
      expect(find.text('Work'), findsOneWidget);
      expect(
        readingOrder(t, find.text('Second')),
        lessThan(readingOrder(t, find.text('First'))),
      );
      await t.longPress(find.text('Second'));
      await t.pumpAndSettle();
      await t.tap(find.text('Unpin'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Clear selection'));
      await t.pumpAndSettle();
      expect(b.organizationWrites, 1);
      expect(
        readingOrder(t, find.text('First')),
        lessThan(readingOrder(t, find.text('Second'))),
      );
      await signOut(t);
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
        home: BrowserAccountPage(
          bridge: b,
          clock: () => 100000,
          accountOnly: true,
          workspaceEnabled: true,
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    final button = t.widget<IconButton>(
      find.byKey(const ValueKey('copy-button-entry/e/99000')),
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
        home: BrowserAccountPage(
          bridge: b,
          clock: () => 100000,
          accountOnly: true,
          workspaceEnabled: true,
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    final before = b.organizationReads;
    final button = t.widget<IconButton>(
      find.byKey(const ValueKey('copy-button-entry/e/99000')),
    );
    button.onPressed!();
    await t.pump();
    expect(b.copyReceipts, 1);
    await signOut(t);
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
        home: BrowserAccountPage(
          bridge: b,
          clock: () => 100000,
          accountOnly: true,
          workspaceEnabled: true,
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('654 321'), findsNothing);
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
          home: BrowserAccountPage(
            bridge: b,
            clock: () => 100000,
            accountOnly: true,
            workspaceEnabled: true,
            loginEnabled: true,
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.longPress(find.text('Example'));
      await t.pumpAndSettle();
      await t.tap(find.text('Pin'));
      await t.pumpAndSettle();
      expect(find.text('Pin'), findsOneWidget);
      expect(find.text('Unpin'), findsNothing);
      expect(find.textContaining('Organization was not saved'), findsOneWidget);
    },
  );
  testWidgets('partial entry view does not shrink saved organization on PUT', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final b = Bridge()
      ..status = 'restored'
      ..clockNow = 100000
      ..entries = [
        {
          'entry_id': 'visible',
          'service_name': 'Visible',
          'capabilities': {'manage': true},
        },
      ]
      ..cloud = {
        'revision': 2,
        'tags': [],
        'entries': [
          {'entryId': 'visible', 'pinned': false, 'tagIds': []},
          {'entryId': 'not-loaded', 'pinned': true, 'tagIds': []},
        ],
        'ranking': [],
      };
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          clock: () => 100000,
          accountOnly: true,
          workspaceEnabled: true,
          loginEnabled: true,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('not-loaded'), findsNothing);
    await t.longPress(find.text('Visible'));
    await t.pumpAndSettle();
    await t.tap(find.text('Pin'));
    await t.pumpAndSettle();
    expect(b.organizationWrites, 1);
    expect(
      (b.cloud['entries'] as List).any(
        (e) => e['entryId'] == 'not-loaded' && e['pinned'] == true,
      ),
      isTrue,
    );
  });
}
