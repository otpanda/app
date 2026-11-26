import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_batch.dart';
import 'package:otpanda_client/totp_tile_code.dart';

// Fake fixtures only. Server time is far from any device clock on purpose.
const serverStart = 1800000010000;

class Rig {
  int mono = 1000;
  int requests = 0;
  late final store = TotpBatchStore(
    fetch: (ids) async {
      requests++;
      final from = serverStart ~/ 30000 * 30;
      return SessionResponse(
        200,
        jsonEncode({
          'serverNow': serverStart,
          'windowSeconds': 600,
          'windowExpiresAt': serverStart + 600000,
          'entries': [
            for (final id in ids)
              {
                'entryId': id,
                'period': 30,
                'digits': 6,
                'validFrom': from,
                'codes': [for (var i = 0; i < 21; i++) '${100000 + i}'],
              },
          ],
          'omitted': [],
        }),
      );
    },
    monotonicMilliseconds: () => mono,
    sessionExpiresAt: () async => serverStart + 3600000,
  );
}

Widget tile(Rig r, {bool hidden = false}) => MaterialApp(
  home: Scaffold(
    body: TotpTileCode(
      batch: r.store,
      entryId: 'a',
      hidden: () => hidden,
      muted: const Color(0xff5d746a),
    ),
  ),
);

class ShellBridge
    implements
        BrowserSessionBridge,
        TotpManagementBridge,
        TotpBatchBridge,
        PageVisibilityBridge {
  bool hiddenNow;
  int batches = 0;
  final requested = <String>{};
  int maxIdsPerRequest = 0;
  final int entries;
  void Function(bool)? listener;
  ShellBridge({this.hiddenNow = false, this.entries = 20});
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get status => 'restored';
  @override
  Future<void> get ready async {}
  @override
  void clear() {}
  @override
  bool get pageHidden => hiddenNow;
  int removed = 0;
  @override
  void Function() onPageVisibility(void Function(bool hidden) l) {
    listener = l;
    return () {
      removed++;
      listener = null;
    };
  }

  void setHidden(bool h) {
    hiddenNow = h;
    listener?.call(h);
  }

  @override
  Future<SessionResponse> read(String path) async {
    Object body;
    switch (path) {
      case '/v1/manage/session':
        body = {'ownerId': 'o', 'expiresAt': serverStart + 3600000};
      case '/v1/manage/entries':
        body = {
          'entries': [
            for (var i = 0; i < entries; i++)
              {
                'entry_id': 'e$i',
                'service_name': 'Svc $i',
                'service_id': 'custom-totp',
                'capabilities': {'manage': true},
              },
          ],
        };
      case '/v1/manage/active-codes':
        body = {'records': []};
      case '/v1/manage/sources':
        body = {'sources': []};
      case '/v1/manage/unassigned':
        body = {'records': []};
      default:
        return const SessionResponse(500, '{}');
    }
    return SessionResponse(200, jsonEncode(body));
  }

  @override
  Future<SessionResponse> totpCodes(List<String> ids) async {
    batches++;
    requested.addAll(ids);
    if (ids.length > maxIdsPerRequest) maxIdsPerRequest = ids.length;
    final from = serverStart ~/ 30000 * 30;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': serverStart,
        'windowSeconds': 600,
        'windowExpiresAt': serverStart + 600000,
        'entries': [
          for (final id in ids)
            {
              'entryId': id,
              'period': 30,
              'digits': 6,
              'validFrom': from,
              'codes': [for (var i = 0; i < 21; i++) '${100000 + i}'],
            },
        ],
        'omitted': [],
      }),
    );
  }
}

Future<ReadWorkspaceController> pumpShell(
  WidgetTester t,
  BrowserSessionBridge b,
) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final c = ReadWorkspaceController(bridge: b, clock: () => serverStart);
  addTearDown(c.dispose);
  await c.refresh();
  await t.pumpWidget(
    MaterialApp(
      theme: otpandaTheme(),
      home: ProductShell(
        controller: c,
        initialTab: 0,
        assignmentEnabled: false,
        entryEditEnabled: false,
        onTabChanged: null,
        onCopyAssigned: (_) async {},
        onCopyPrivate: (_) async {},
        clock: () => serverStart,
        onSignedOut: () {},
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  return c;
}

void main() {
  testWidgets('tile shows the batch code with seconds left and ticks locally', (
    t,
  ) async {
    final r = Rig();
    await r.store.ensure(['a']);
    expect(r.requests, 1);
    await t.pumpWidget(tile(r));
    expect(find.text('100 000'), findsOneWidget);
    expect(find.text('20 s'), findsOneWidget);
    r.mono += 21000;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('100 001'), findsOneWidget);
    expect(r.requests, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('tile never shows an expired or cleared batch', (t) async {
    final r = Rig();
    await r.store.ensure(['a']);
    await t.pumpWidget(tile(r));
    expect(find.text('100 000'), findsOneWidget);
    r.mono += 600001;
    await t.pump(const Duration(seconds: 1));
    expect(find.text('100 000'), findsNothing);
    expect(find.text('Code not loaded'), findsOneWidget);
    final r2 = Rig();
    await r2.store.ensure(['a']);
    await t.pumpWidget(tile(r2));
    r2.store.clear();
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('100 0'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a hidden tile shows no code and makes no request', (t) async {
    final r = Rig();
    await r.store.ensure(['a']);
    await t.pumpWidget(tile(r, hidden: true));
    await t.pump(const Duration(seconds: 3));
    expect(find.text('100 000'), findsNothing);
    expect(r.requests, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shell: 20 TOTP entries load as four sequential requests and tiles show codes',
    (t) async {
      final b = ShellBridge();
      await pumpShell(t, b);
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(b.batches, 4);
      expect(find.text('100 000'), findsWidgets);
      expect(find.text('Code not loaded'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shell: nothing is requested while the page is hidden; showing it loads once',
    (t) async {
      final b = ShellBridge(hiddenNow: true);
      await pumpShell(t, b);
      await t.pump(const Duration(seconds: 6));
      expect(b.batches, 0);
      expect(find.text('100 000'), findsNothing);
      b.setHidden(false);
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(b.batches, 4);
      expect(find.text('100 000'), findsWidgets);
      b.setHidden(true);
      await t.pump(const Duration(seconds: 6));
      expect(b.batches, 4);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shell: disposing removes the page visibility listener', (
    t,
  ) async {
    final b = ShellBridge();
    await pumpShell(t, b);
    expect(b.listener, isNotNull);
    await t.pumpWidget(const SizedBox());
    expect(b.removed, 1);
    expect(b.listener, isNull);
  });

  // Cap semantics (see totp_batch.dart): the cap is per call. One call tracks
  // at most 20 entries, as at most 4 sequential requests of at most 5. It is not
  // a limit on distinct entries fetched over a window, because entries that are
  // already cached are not requested again and a new search may need new ones.
  testWidgets(
    'shell: a search match beyond 20 is fetched first, within the per-call cap, after a pause',
    (t) async {
      final b = ShellBridge(entries: 30);
      await pumpShell(t, b);
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(b.requested.contains('e25'), isFalse);
      final before = b.batches;
      final field = find.byKey(const ValueKey('search-0'));
      await t.enterText(field, 'S');
      await t.enterText(field, 'Svc');
      await t.enterText(field, 'Svc 25');
      await t.pump(const Duration(milliseconds: 200));
      expect(b.batches, before); // still typing: no request yet
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle(const Duration(milliseconds: 100));
      expect(b.requested.contains('e25'), isTrue);
      expect(b.batches - before, lessThanOrEqualTo(totpBatchMaxChain));
      expect(b.maxIdsPerRequest, lessThanOrEqualTo(totpBatchMaxEntries));
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shell: disposing cancels a pending search check', (t) async {
    final b = ShellBridge(entries: 30);
    await pumpShell(t, b);
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    final before = b.batches;
    await t.enterText(find.byKey(const ValueKey('search-0')), 'Svc 25');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    expect(b.batches, before);
    expect(t.takeException(), isNull);
  });

  testWidgets('shell without a batch bridge keeps the old tile', (t) async {
    final b = _NoBatch();
    await pumpShell(t, b);
    expect(find.byType(TotpTileCode), findsNothing);
    expect(find.text('No active code'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });
}

// Same routes, but no batch or visibility capability (native or extension).
class _NoBatch implements BrowserSessionBridge, TotpManagementBridge {
  final inner = ShellBridge(entries: 2);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get status => 'restored';
  @override
  Future<void> get ready async {}
  @override
  void clear() {}
  @override
  Future<SessionResponse> read(String path) => inner.read(path);
}
