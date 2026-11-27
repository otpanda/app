import 'package:flutter/services.dart';
import 'package:otpanda_client/copy_hint.dart';
import 'package:otpanda_client/organization_contract.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/profile_header.dart';
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
  Future<SessionResponse> Function(String)? handler;
  FakeTransport(this.routes);
  @override
  Future<SessionResponse> read(String path) async {
    calls++;
    if (handler != null) return handler!(path);
    return routes[path] ?? const SessionResponse(500, '{}');
  }
}

class ManagedFake extends FakeTransport
    implements EntryManagementBridge, EntryDeleteBridge {
  final calls2 = <String>[];
  Object? failWith;
  int? failAfter;
  ManagedFake(super.routes);
  Future<void> _do(String c) async {
    calls2.add(c);
    if (failAfter != null && calls2.length > failAfter!) throw StateError('x');
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> renameEntry(String id, String label) => _do('rename $id $label');
  @override
  Future<void> updateAccount(String id, String? a) => _do('account $id $a');
  @override
  Future<void> deleteEntry(String id) => _do('delete $id');
}

class RenameOnlyFake extends FakeTransport implements EntryManagementBridge {
  RenameOnlyFake(super.routes);
  @override
  Future<void> renameEntry(String id, String label) async {}
  @override
  Future<void> updateAccount(String id, String? a) async {}
}

class AssignFake extends FakeTransport implements AssignmentBridge {
  final prepared = <String>[];
  String st = 'idle';
  AssignFake(super.routes);
  @override
  Future<String> assignmentPrepare(String target) async {
    prepared.add(target);
    throw StateError('stop here');
  }

  @override
  Future<String> assignmentConfirm() async => 'idle';
  @override
  Future<String> assignmentReconcile() async => 'idle';
  @override
  String get assignmentState => st;
  @override
  void assignmentDismiss() {}
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

Future<void> pump(
  WidgetTester t,
  FakeTransport tr, {
  bool out = false,
  bool assignmentEnabled = false,
  bool entryEditEnabled = true,
  CopyHintStore? copyHintStore,
  OrganizationStore? organization,
  bool showTags = false,
  String? navigation,
  ValueChanged<String>? onNavigate,
}) async {
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
        showHeaderBrand: true, // Existing shell layout/goldens exercise web chrome.
        controller: controller,
        navigation: navigation,
        onNavigate: onNavigate,
        organization: organization,
        showTileTags: showTags,
        copyHintStore: copyHintStore,
        assignmentEnabled: assignmentEnabled,
        entryEditEnabled: entryEditEnabled,
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
  setUpAll(() async {
    if (Platform.isLinux) {
      for (final family in ['Figtree', 'BricolageGrotesque']) {
        final loader = FontLoader(family);
        for (final weight
            in (family == 'Figtree' ? [400, 500, 600, 700] : [700, 800])) {
          final name = family == 'Figtree' ? 'Figtree' : 'BricolageGrotesque';
          loader.addFont(
            Future.value(
              ByteData.sublistView(
                File('assets/fonts/$name-$weight.ttf').readAsBytesSync(),
              ),
            ),
          );
        }
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File(
                '${Platform.environment['FLUTTER_ROOT'] ?? '/downloads/otpanda/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytesSync(),
            ),
          ),
        );
      await icons.load();
      final mono = FontLoader('CodeMono')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/CodeMono-Regular.ttf').readAsBytesSync(),
            ),
          ),
        );
      await mono.load();
    }
  });

  testWidgets(
    'shared routed Details is read-only even with management-capable transport',
    (t) async {
      final tr = ManagedFake(
        routes(
          entries: [
            {
              'entry_id': 'a',
              'service_name': 'Shared',
              'account_name': 'viewer',
              'capabilities': {'manage': false},
            },
          ],
        ),
      );
      await pump(t, tr, navigation: 'accounts/YQ');
      expect(find.byKey(const Key('account-details')), findsOneWidget);
      expect(find.byKey(const Key('entry-edit')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const Key('entry-save')), findsNothing);
      expect(find.byKey(const Key('entry-delete')), findsNothing);
      expect(tr.calls2, isEmpty);
    },
  );
  testWidgets('missing routed account returns home once after completed load', (
    t,
  ) async {
    final log = <String>[];
    await pump(
      t,
      FakeTransport(routes()),
      navigation: 'accounts/bWlzc2luZw',
      onNavigate: log.add,
    );
    await t.pump(const Duration(seconds: 3));
    expect(log, ['codes']);
    expect(find.byKey(const Key('account-details')), findsNothing);
  });
  testWidgets(
    'missing unassigned route returns home once when code and review absent',
    (t) async {
      final log = <String>[];
      await pump(
        t,
        FakeTransport(routes()),
        navigation: 'unassigned-details/c3Jj/ZXZlbnQ',
        onNavigate: log.add,
      );
      await t.pump(const Duration(seconds: 3));
      expect(log, ['codes']);
      expect(find.byKey(const Key('unassigned-details')), findsNothing);
    },
  );
  testWidgets(
    '32-character code and placeholder fit narrow screen without changing length',
    (t) async {
      final entry = {
        'entry_id': 'e',
        'service_name': 'Acme',
        'account_name': 'me',
        'digits': 32,
        'capabilities': {'manage': true},
      };
      await pump(t, FakeTransport(routes(entries: [entry])));
      expect(find.text('-' * 32), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await pump(
        t,
        FakeTransport(
          routes(
            entries: [entry],
            codes: [
              {
                'entryId': 'e',
                'code': '1' * 32,
                'receivedAt': now - 1,
                'expiresAt': now + 60000,
              },
            ],
          ),
        ),
      );
      expect(find.text('1' * 32), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'first-use copy hint disappears only after success and stays gone',
    (t) async {
      final pref = TestCopyHint();
      final tr = FakeTransport(
        routes(
          entries: [
            {
              'entry_id': 'e',
              'service_name': 'Acme',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'e',
              'code': '123456',
              'receivedAt': now - 1000,
              'expiresAt': now + 60000,
            },
          ],
        ),
      );
      await pump(t, tr, copyHintStore: pref);
      expect(find.text('Tap a card to copy'), findsOneWidget);
      await t.tap(find.text('Acme'));
      await t.pump();
      expect(find.text('Copied'), findsOneWidget);
      expect(find.text('Tap a card to copy'), findsNothing);
      expect(pref.seen, true);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await pump(t, tr, copyHintStore: pref);
      expect(find.text('Tap a card to copy'), findsNothing);
    },
  );

  testWidgets('tutorial can be dismissed and stays dismissed on this device', (
    t,
  ) async {
    final pref = TestCopyHint();
    final tr = FakeTransport(
      routes(
        entries: [
          {
            'entry_id': 'e',
            'service_name': 'Acme',
            'account_name': 'me',
            'capabilities': {'manage': true},
          },
        ],
        codes: [
          {
            'entryId': 'e',
            'code': '123456',
            'receivedAt': now - 1000,
            'expiresAt': now + 60000,
          },
        ],
      ),
    );
    await pump(t, tr, copyHintStore: pref);
    expect(find.byKey(const Key('copy-tutorial-banner')), findsOneWidget);
    await t.tap(find.byKey(const Key('dismiss-copy-tutorial')));
    await t.pump();
    expect(find.byKey(const Key('copy-tutorial-banner')), findsNothing);
    expect(pref.seen, true);
    await t.pumpWidget(const SizedBox());
    await pump(t, tr, copyHintStore: pref);
    expect(find.byKey(const Key('copy-tutorial-banner')), findsNothing);
  });

  testWidgets(
    'no tutorial for empty or placeholder, appears when copyable code arrives',
    (t) async {
      final pref = TestCopyHint();
      final tr = FakeTransport(routes(entries: [], codes: []));
      await pump(t, tr, copyHintStore: pref);
      expect(find.byKey(const Key('copy-tutorial-banner')), findsNothing);
      expect(pref.seen, false);
      tr.routes.addAll(
        routes(
          entries: [
            {
              'entry_id': 'e',
              'service_name': 'Acme',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [],
        ),
      );
      await t.pumpWidget(const SizedBox());
      await pump(t, tr, copyHintStore: pref);
      expect(find.byKey(const Key('copy-tutorial-banner')), findsNothing);
      expect(pref.seen, false);
      tr.routes.addAll(
        routes(
          entries: [
            {
              'entry_id': 'e',
              'service_name': 'Acme',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'e',
              'code': '123456',
              'receivedAt': now - 1000,
              'expiresAt': now + 60000,
            },
          ],
        ),
      );
      await t.pumpWidget(const SizedBox());
      await pump(t, tr, copyHintStore: pref);
      expect(find.byKey(const Key('copy-tutorial-banner')), findsOneWidget);
      expect(find.text('START HERE'), findsNothing);
      expect(pref.seen, false);
    },
  );

  testWidgets(
    'wide copy button and whole tile both copy, mobile alone has hint',
    (t) async {
      final pref = TestCopyHint();
      final tr = FakeTransport(
        routes(
          entries: [
            {
              'entry_id': 'e',
              'service_name': 'Acme',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'e',
              'code': '123456',
              'receivedAt': now - 1000,
              'expiresAt': now + 60000,
            },
          ],
        ),
      );
      await pump(t, tr, copyHintStore: pref);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.text('Tap a card to copy'), findsOneWidget);
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/responsive-copy-mobile.png'),
        );
      }
      t.view.physicalSize = const Size(320, 740);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/copy-tutorial-narrow.png'),
        );
      }
      t.platformDispatcher.textScaleFactorTestValue = 1.6;
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/copy-tutorial-large-text.png'),
        );
      }
      t.platformDispatcher.clearTextScaleFactorTestValue();
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(1200, 900);
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
      expect(find.text('Tap a card to copy'), findsNothing);
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/responsive-copy-desktop.png'),
        );
      }
      await t.tap(find.byIcon(Icons.copy_outlined));
      await t.pump();
      expect(find.text('Copied'), findsOneWidget);
      expect(pref.seen, true);
      await t.pump(const Duration(seconds: 2));
      await t.tap(find.text('Acme'));
      await t.pump();
      expect(find.text('Copied'), findsOneWidget);
      t.view.physicalSize = const Size(390, 844);
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.text('Tap a card to copy'), findsNothing);
      await t.pumpWidget(const SizedBox());
      await pump(t, tr, copyHintStore: TestCopyHint());
      expect(find.text('Tap a card to copy'), findsOneWidget);
    },
  );
  testWidgets(
    'hint refresh failure retains visible code without transient warning',
    (t) async {
      var time = now;
      final tr = FakeTransport(
        routes(
          entries: [
            {
              'entry_id': 'e',
              'service_name': 'Example',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'e',
              'code': '123456',
              'receivedAt': now,
              'expiresAt': now + 300000,
            },
          ],
        ),
      );
      final c = ReadWorkspaceController(bridge: tr, clock: () => time);
      await c.refresh();
      await t.pumpWidget(
        MaterialApp(
          home: ProductShell(
            controller: c,
            clock: () => time,
            onSignedOut: () {},
            onCopyAssigned: (_) async {},
            onCopyPrivate: (_) async {},
          ),
        ),
      );
      expect(find.byTooltip('Copy code'), findsNothing);
      time += 30000;
      final pending = Completer<SessionResponse>();
      tr.handler = (_) => pending.future;
      final poll = c.refresh();
      await t.pump();
      expect(find.byTooltip('Copy code'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.complete(const SessionResponse(503, '{}'));
      await poll;
      await t.pump();
      expect(find.byTooltip('Copy code'), findsNothing);
      expect(find.textContaining('Connection interrupted'), findsNothing);
      expect(
        find.textContaining('Connection to the server was lost'),
        findsNothing,
      );
      c.dispose();
    },
  );

  testWidgets(
    'actual mobile hold selects, toolbar tags creates inline, timer remains bottom',
    (t) async {
      final org = OrganizationStore()..reconcileEntries(['a']);
      final tr = ManagedFake(
        routes(
          entries: [
            {
              'entry_id': 'a',
              'service_name': 'Alpha',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'a',
              'code': '123456',
              'receivedAt': now - 180000,
              'expiresAt': now + 60000,
            },
          ],
        ),
      );
      await pump(t, tr, organization: org, showTags: true);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byTooltip('Copy code'), findsNothing);
      await t.longPress(find.text('Alpha'));
      await t.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(
        t.widget<TextButton>(find.byKey(const Key('edit-a'))).onPressed,
        isNotNull,
      );
      expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, 'Share'))
            .onPressed,
        isNull,
      );
      await t.tap(find.text('Tags'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'New tag'), 'Work');
      await t.pump();
      await t.tap(find.byTooltip('Create tag'));
      await t.pumpAndSettle();
      expect(find.text('Work'), findsOneWidget);
      await t.tap(find.text('Apply'));
      await t.pumpAndSettle();
      expect(org.preferencesFor('a').tagIds, isNotEmpty);
      expect(find.byIcon(Icons.sell_outlined), findsNWidgets(2));
      expect(find.text('Manage tags'), findsNothing);
      expect(t.takeException(), isNull);
      if (Platform.environment['SCREENSHOT_DIR'] != null) {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        await t.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Platform.environment['SCREENSHOT_DIR']}/ui-mobile-selection-tags.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await t.tap(find.byTooltip('Clear selection'));
      await t.pumpAndSettle();
      await t.drag(find.byType(ListView).first, const Offset(0, 100));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('account-sort-button')), findsOneWidget);
      await t.tap(find.byKey(const Key('account-sort-button')));
      await t.pumpAndSettle();
      expect(find.text('Frequently used'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('unified Codes has no tab navigation', (t) async {
    await pump(t, FakeTransport(routes()));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Sources'), findsNothing);
    expect(t.takeException(), isNull);
  });

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

  testWidgets('fresh received codes sit on top, highlighted; old ones do not', (
    t,
  ) async {
    final r = routes(
      entries: [
        for (final (id, n) in [('a', 'Alpha'), ('b', 'Bravo')])
          {
            'entry_id': id,
            'service_name': n,
            'account_name': 'me',
            'capabilities': {'manage': true},
          },
      ],
      codes: [
        {
          'entryId': 'a',
          'code': '111111',
          'receivedAt': now - 600000 + 590000 - 500000,
          'expiresAt': now + 60000,
        },
        {
          'entryId': 'b',
          'code': '222222',
          'receivedAt': now - 3000,
          'expiresAt': now + 60000,
        },
      ],
    );
    r['/v1/manage/sources'] = ok({
      'sources': [
        {'source_id': 's', 'kind': 'gmail', 'label': 'me@example.test'},
      ],
    });
    r['/v1/manage/unassigned'] = ok({
      'records': [
        {
          'sourceId': 's',
          'eventId': 'v',
          'code': '333333',
          'receivedAt': now - 2000,
          'expiresAt': now + 60000,
        },
      ],
    });
    await pump(t, FakeTransport(r));
    expect(find.text('New arrivals'), findsOneWidget);
    expect(
      find.byKey(const Key('fresh-Unassigned code-333333')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fresh-Bravo-222222')), findsOneWidget);
    // The older code is listed normally, once, below the fresh ones.
    expect(find.byKey(const Key('fresh-Alpha-111111')), findsNothing);
    expect(find.text('111 111'), findsOneWidget);
    expect(find.text('222 222'), findsOneWidget);
    final top = t.getTopLeft(find.text('333 333')).dy;
    expect(top, lessThan(t.getTopLeft(find.text('111 111')).dy));
    expect(
      t.getTopLeft(find.text('222 222')).dy,
      lessThan(t.getTopLeft(find.text('111 111')).dy),
    );
  });

  testWidgets('only unassigned codes still show on the Codes tab', (t) async {
    final r = routes();
    r['/v1/manage/sources'] = ok({
      'sources': [
        {'source_id': 's', 'kind': 'gmail', 'label': 'me@example.test'},
      ],
    });
    r['/v1/manage/unassigned'] = ok({
      'records': [
        {
          'sourceId': 's',
          'eventId': 'v',
          'code': '444444',
          'receivedAt': now - 2000,
          'expiresAt': now + 60000,
        },
      ],
    });
    await pump(t, FakeTransport(r));
    expect(find.text('No codes yet'), findsNothing);
    expect(find.text('444 444'), findsOneWidget);
  });

  testWidgets('no highlight without recent received codes', (t) async {
    await pump(
      t,
      FakeTransport(
        routes(
          entries: [
            {
              'entry_id': 'a',
              'service_name': 'Alpha',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
          codes: [
            {
              'entryId': 'a',
              'code': '555555',
              'receivedAt': now - 200000,
              'expiresAt': now + 60000,
            },
          ],
        ),
      ),
    );
    expect(find.text('New arrivals'), findsNothing);
    expect(find.text('555 555'), findsOneWidget);
  });

  testWidgets('failed read is not shown as an empty account', (t) async {
    await pump(t, FakeTransport({}));
    expect(find.text('Could not load your codes'), findsOneWidget);
    expect(find.text('No codes yet'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.textContaining('retry automatically'), findsWidgets);
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
    expect(find.text('Updating your codes automatically'), findsOneWidget);
    expect(find.text('No codes yet'), findsNothing);
    expect(bridge.calls, 6);
  });

  Map<String, SessionResponse> twoEntries({bool manage = true}) => routes(
    entries: [
      {
        'entry_id': 'a',
        'service_name': 'Alpha',
        'account_name': 'me',
        'capabilities': {'manage': manage},
      },
    ],
  );

  testWidgets(
    'direct account details is full-page and inaccessible IDs return home',
    (t) async {
      final log = <String>[];
      await pump(
        t,
        ManagedFake(twoEntries()),
        navigation: 'accounts/YQ',
        onNavigate: log.add,
      );
      expect(find.byKey(const Key('account-details')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Added'), findsNothing); // no invented date
      expect(find.text('Type'), findsNothing);
      expect(find.text('Tags'), findsOneWidget);
      await t.tap(find.byTooltip('Back to codes'));
      expect(log.last, 'codes');
      await pump(
        t,
        ManagedFake(twoEntries()),
        navigation: 'accounts/bWlzc2luZw',
        onNavigate: log.add,
      );
      expect(log.last, 'codes');
      expect(find.byKey(const Key('account-details')), findsNothing);
    },
  );

  testWidgets('entries: no edit controls without the capability or ownership', (
    t,
  ) async {
    await pump(t, FakeTransport(twoEntries()));
    expect(find.byKey(const Key('edit-a')), findsNothing);
    await pump(t, ManagedFake(twoEntries(manage: false)));
    expect(find.byKey(const Key('edit-a')), findsNothing);
    await pump(t, ManagedFake(twoEntries()), entryEditEnabled: false);
    expect(find.byKey(const Key('edit-a')), findsNothing);
  });

  testWidgets(
    'entries: a long label ellipsizes and keeps a gap before the status',
    (t) async {
      final r = routes(
        entries: [
          {
            'entry_id': 'a',
            'service_name':
                'A very long service name that cannot possibly fit on one line',
            'account_name': 'someone.with.a.long.address@example.test',
            'capabilities': {'manage': true},
          },
        ],
      );
      await pump(t, ManagedFake(r));
      final status = t.getTopLeft(find.text('------'));
      final title = find.textContaining('A very long service');
      expect(t.getTopRight(title).dx + 8, lessThanOrEqualTo(status.dx));
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('entries: rename and account change, then list reloads', (
    t,
  ) async {
    final tr = ManagedFake(twoEntries());
    await pump(t, tr);
    await t.longPress(find.text('Alpha'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('edit-a')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('entry-save')), findsNothing);
    await t.tap(find.byKey(const Key('entry-edit')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('entry-name')), 'Alpha Two');
    await t.enterText(find.byKey(const Key('entry-account')), '');
    await t.pump();
    await t.tap(find.byKey(const Key('entry-save')));
    await t.pumpAndSettle();
    expect(tr.calls2, ['rename a Alpha Two', 'account a null']);
    expect(find.byKey(const Key('account-details')), findsNothing);
    // Shown at once: the test clock never reopens the read gate, so no reload
    // could have supplied it.
    expect(find.text('Alpha Two'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('me'), findsNothing);
    expect(tr.calls, 6);
  });

  testWidgets(
    'entries: a confirmed rename shows at once on Codes and in search',
    (t) async {
      final r = twoEntries();
      final tr = ManagedFake(r);
      await pump(t, tr);
      await t.longPress(find.text('Alpha'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('edit-a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('entry-edit')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('entry-name')), 'Gamma');
      await t.pump();
      await t.tap(find.byKey(const Key('entry-save')));
      await t.pumpAndSettle();
      expect(find.text('Gamma'), findsOneWidget);
      // Unified page stays on Codes after the edit. No tab navigation.
      await t.pumpAndSettle();
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
      final field = find.descendant(
        of: find.byKey(const Key('product-top-bar')),
        matching: find.byType(TextField),
      );
      await t.enterText(field, 'gamma');
      await t.pumpAndSettle();
      expect(find.text('Gamma'), findsOneWidget);
      await t.enterText(field, 'alpha');
      await t.pumpAndSettle();
      expect(find.text('Gamma'), findsNothing);
    },
  );

  testWidgets(
    'entries: only the confirmed half shows when the second call fails',
    (t) async {
      final tr = ManagedFake(twoEntries());
      await pump(t, tr);
      await t.longPress(find.text('Alpha'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('edit-a')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('entry-edit')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('entry-name')), 'Delta');
      await t.enterText(find.byKey(const Key('entry-account')), 'you');
      await t.pump();
      tr.failAfter = 1;
      await t.tap(find.byKey(const Key('entry-save')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('entry-error')), findsOneWidget);
      expect(tr.calls2, ['rename a Delta', 'account a you']);
      await t.tap(find.byKey(const Key('entry-cancel')));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Back to codes'));
      await t.pumpAndSettle();
      expect(find.text('Delta'), findsOneWidget);
      expect(find.text('me'), findsOneWidget);
      expect(find.text('you'), findsNothing);
    },
  );

  test('a read that started before a confirmed edit cannot bring the old label back', () async {
    var clock = now;
    final gate = Completer<void>();
    var stale = false;
    final tr = FakeTransport(twoEntries())
      ..handler = (path) async {
        if (stale && path.endsWith('entries')) await gate.future;
        return twoEntries()[path] ?? const SessionResponse(500, '{}');
      };
    final c = ReadWorkspaceController(bridge: tr, clock: () => clock);
    await c.refresh();
    expect(c.store.entries.single.service, 'Alpha');
    clock += 20000;
    stale = true;
    final inFlight = c.refresh();
    await Future<void>.delayed(Duration.zero);
    c.applyEntryEdit('a', service: 'Omega');
    expect(c.store.entries.single.service, 'Omega');
    gate.complete();
    await inFlight;
    expect(c.store.entries.single.service, 'Omega');
    // A later read that began after the edit now carries the server value.
    clock += 20000;
    stale = false;
    await c.refresh();
    expect(c.store.entries.single.service, 'Alpha');
    c.dispose();
  });

  test(
    'a confirmed edit for an entry the list does not have changes nothing',
    () async {
      final tr = FakeTransport(twoEntries());
      final c = ReadWorkspaceController(bridge: tr, clock: () => now);
      await c.refresh();
      final rev = c.publishedRevision;
      c.applyEntryEdit('nope', service: 'X');
      expect(c.store.entries.single.service, 'Alpha');
      expect(c.publishedRevision, greaterThanOrEqualTo(rev));
      c.dispose();
    },
  );

  testWidgets('entries: empty name cannot be saved', (t) async {
    await pump(t, ManagedFake(twoEntries()));
    await t.longPress(find.text('Alpha'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('edit-a')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('entry-edit')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('entry-name')), '  ');
    await t.pump();
    expect(
      t.widget<FilledButton>(find.byKey(const Key('entry-save'))).onPressed,
      isNull,
    );
  });

  testWidgets('entries: delete asks first, Cancel deletes nothing', (t) async {
    final tr = ManagedFake(twoEntries());
    await pump(t, tr);
    await t.longPress(find.text('Alpha'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('edit-a')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('entry-edit')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('entry-delete')));
    await t.tap(find.byKey(const Key('entry-delete')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('entry-delete-confirm')), findsOneWidget);
    await t.tap(find.text('Cancel').last);
    await t.pumpAndSettle();
    expect(tr.calls2, isEmpty);
    await t.ensureVisible(find.byKey(const Key('entry-delete')));
    await t.tap(find.byKey(const Key('entry-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('entry-delete-yes')));
    await t.pumpAndSettle();
    expect(tr.calls2, ['delete a']);
    expect(find.byKey(const Key('account-details')), findsNothing);
  });

  testWidgets('entries: failed change stays open, says unconfirmed, no retry', (
    t,
  ) async {
    final tr = ManagedFake(twoEntries())..failWith = StateError('x');
    await pump(t, tr);
    await t.longPress(find.text('Alpha'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('edit-a')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('entry-edit')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('entry-name')), 'Beta');
    await t.pump();
    await t.tap(find.byKey(const Key('entry-save')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('entry-error')), findsOneWidget);
    expect(find.byKey(const Key('account-details')), findsOneWidget);
    expect(tr.calls2, ['rename a Beta']);
  });

  Map<String, SessionResponse> withPrivateCode() {
    final r = twoEntries();
    r['/v1/manage/sources'] = ok({
      'sources': [
        {'source_id': 's', 'kind': 'gmail', 'label': 'me@example.test'},
      ],
    });
    r['/v1/manage/unassigned'] = ok({
      'records': [
        {
          'sourceId': 's',
          'eventId': 'v',
          'code': '666666',
          'receivedAt': now - 2000,
          'expiresAt': now + 60000,
        },
      ],
    });
    return r;
  }

  testWidgets('assign: hidden unless enabled and the bridge supports it', (
    t,
  ) async {
    await pump(t, AssignFake(withPrivateCode()));
    expect(find.byKey(const Key('assign-v')), findsNothing);
    await pump(t, FakeTransport(withPrivateCode()), assignmentEnabled: true);
    expect(find.byKey(const Key('assign-v')), findsNothing);
    expect(find.text('666 666'), findsOneWidget);
  });

  testWidgets('assign: picks an owned entry, then only asks to prepare it', (
    t,
  ) async {
    final tr = AssignFake(withPrivateCode());
    await pump(t, tr, assignmentEnabled: true);
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await t.tap(find.byKey(const Key('assign-v')));
    await t.pumpAndSettle();
    expect(copied, isNull);
    expect(find.text('Copied'), findsNothing);
    expect(find.byKey(const Key('assign-picker')), findsOneWidget);
    await t.tap(find.byKey(const Key('assign-picker-cancel')));
    await t.pumpAndSettle();
    expect(tr.prepared, isEmpty);
    await t.tap(find.byKey(const Key('assign-v')));
    await t.pumpAndSettle();
    // Choosing a target assigns nothing by itself.
    expect(tr.prepared, isEmpty);
    await t.tap(find.byKey(const Key('assign-to-a')));
    await t.pumpAndSettle();
    expect(tr.prepared, hasLength(1));
    final sent = jsonDecode(tr.prepared.single) as Map;
    expect(sent, {'sourceId': 's', 'eventId': 'v', 'entryId': 'a'});
  });

  testWidgets('search lives in the top bar; no in-page title', (t) async {
    final semantics = t.ensureSemantics();
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
            {
              'entry_id': 'e2',
              'service_name': 'Zed',
              'account_name': 'me',
              'capabilities': {'manage': true},
            },
          ],
        ),
      ),
    );
    final bar = find.byKey(const Key('product-top-bar'));
    final field = find.descendant(of: bar, matching: find.byType(TextField));
    expect(field, findsOneWidget);
    expect(find.text('Your codes'), findsNothing);
    // Mobile: icon, search, account only.
    expect(
      find.descendant(of: bar, matching: find.text('OTPanda')),
      findsNothing,
    );
    expect(find.text('Search accounts'), findsOneWidget);
    expect(find.text('Search services or accounts'), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp('Search services or accounts')),
      findsOneWidget,
    );
    await t.enterText(field, 'acme');
    await t.pumpAndSettle();
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('Zed'), findsNothing);
    await t.tap(find.byKey(const Key('search-clear')));
    await t.pumpAndSettle();
    expect(find.text('Zed'), findsOneWidget);
    expect(t.widget<TextField>(field).controller!.text, '');
    // Unified page retains the search until the explicit clear action.
    await t.enterText(field, 'zed');
    await t.pumpAndSettle();
    expect(find.text('Zed'), findsOneWidget);
    expect(find.text('Acme'), findsNothing);
    semantics.dispose();
  });

  testWidgets('desktop top bar keeps the wordmark beside the search', (
    t,
  ) async {
    await pump(t, FakeTransport(routes()));
    t.view.physicalSize = const Size(1280, 720);
    await t.pumpAndSettle();
    final bar = find.byKey(const Key('product-top-bar'));
    expect(
      find.descendant(of: bar, matching: find.text('OTPanda')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(TextField)),
      findsOneWidget,
    );
  });

  testWidgets('desktop top bar aligns the search with the content below', (
    t,
  ) async {
    await pump(t, FakeTransport(routes()));
    t.view.physicalSize = const Size(1600, 900);
    await t.pumpAndSettle();
    final bar = find.byKey(const Key('product-top-bar'));
    final field = find.descendant(of: bar, matching: find.byType(TextField));
    expect(field, findsOneWidget);
    // The body is a centered 1100-wide grid: a 232-wide nav column, the
    // content column, then a 24-wide right gap. The header mirrors it.
    const gridLeft = (1600 - 1100) / 2;
    const gridRight = gridLeft + 1100;
    // The search fills the content column from its left edge.
    expect(t.getTopLeft(field).dx, gridLeft + 180);
    // The brand aligns with the first nav tile below it.
    final logo = find.descendant(of: bar, matching: find.byType(Image));
    expect(t.getTopLeft(logo).dx, gridLeft + 24);
    // The account button ends at the content column's right edge.
    final account = find.descendant(of: bar, matching: find.byType(IconButton));
    expect(account, findsOneWidget);
    expect(t.getTopRight(account).dx, gridRight - 24);
    // Narrower desktop: the grid stops centering and hugs the left edge.
    t.view.physicalSize = const Size(800, 900);
    await t.pumpAndSettle();
    expect(t.getTopLeft(field).dx, 180);
    expect(t.getTopLeft(logo).dx, 24);
  });

  // The sources are read from the composed header right after the first
  // frame. No further frame is pumped, so the test never depends on when the
  // test HTTP client fails an image request.
  Future<List<String>> headerAvatarUrls(
    WidgetTester t, {
    String? picture,
  }) async {
    final tr = FakeTransport(routes());
    final controller = ReadWorkspaceController(bridge: tr, clock: () => now);
    addTearDown(controller.dispose);
    await controller.refresh();
    await t.pumpWidget(
      MaterialApp(
        theme: otpandaTheme(),
        home: ProductShell(
          controller: controller,
          profileEmail: 'person@example.com',
          profilePicture: picture,
          onCopyAssigned: (_) async {},
          onCopyPrivate: (_) async {},
          clock: () => now,
          onSignedOut: () {},
        ),
      ),
    );
    final avatar = find.byType(ProfileAvatar);
    expect(avatar, findsOneWidget);
    return [
      for (final i in t.widgetList<Image>(
        find.descendant(of: avatar, matching: find.byType(Image)),
      ))
        (i.image as NetworkImage).url,
    ];
  }

  testWidgets('home header avatar falls back to Gravatar like Settings', (
    t,
  ) async {
    expect(await headerAvatarUrls(t), [gravatarUrl('person@example.com')]);
  });

  testWidgets('home header avatar tries the Google picture first', (t) async {
    const g = 'https://lh3.googleusercontent.com/a/example=s96-c';
    expect(await headerAvatarUrls(t, picture: g), [g]);
  });
}

class TestCopyHint implements CopyHintStore {
  bool seen = false;
  @override
  Future<bool> copiedBefore() async => seen;
  @override
  Future<void> markCopied() async {
    seen = true;
  }
}
