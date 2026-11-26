import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:otpanda_client/main_page_batch.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_batch_contract.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/main.dart';
import 'package:material_ui/material_ui.dart';

import 'product_shell_test.dart' show FakeTransport;

class BatchBridge extends FakeTransport implements TotpBatchBridge {
  BatchBridge(super.routes);
  int batches = 0;
  final requests = <List<String>>[];
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    requests.add(List.of(ids));
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': 45000,
        'coverageUntil': 600000,
        'totalCodes': 20 * ids.length,
        'entries': [
          for (final id in ids)
            {
              'entryId': id,
              'period': 30,
              'digits': 7,
              'validFrom': 30,
              'codes': List.filled(20, '0000001'),
            },
        ],
        'omitted': [],
      }),
    );
  }
}

class HorizonBridge extends FakeTransport implements TotpBatchBridge {
  HorizonBridge(super.routes);
  int now = 45000;
  final requests = <List<String>>[];
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    requests.add(List.of(ids));
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': now,
        'coverageUntil': now + 10000,
        'totalCodes': ids.length,
        'entries': [
          for (final id in ids)
            {
              'entryId': id,
              'period': 30,
              'digits': 7,
              'validFrom': now ~/ 30000 * 30,
              'codes': ['0000001'],
            },
        ],
        'omitted': [],
      }),
    );
  }
}

class FailingBatchBridge extends FakeTransport implements TotpBatchBridge {
  FailingBatchBridge(super.routes);
  int batches = 0;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    return const SessionResponse(429, '{}');
  }
}

class OmittedBridge extends FakeTransport implements TotpBatchBridge {
  OmittedBridge(super.routes);
  int batches = 0;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': 59600,
        'coverageUntil': null,
        'totalCodes': 0,
        'entries': [],
        'omitted': [
          for (final id in ids) {'entryId': id, 'reason': 'period_too_short'},
        ],
      }),
    );
  }
}

class CurrentOnlyBridge extends FakeTransport implements TotpBatchBridge {
  CurrentOnlyBridge(super.routes);
  int batches = 0;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': 59600,
        'coverageUntil': 60000,
        'totalCodes': ids.length,
        'entries': [
          for (final id in ids)
            {
              'entryId': id,
              'period': 30,
              'digits': 7,
              'validFrom': 30,
              'codes': ['0000001'],
            },
        ],
        'omitted': [],
      }),
    );
  }
}

void main() {
  test(
    'sleep divergence clears held codes and stale copy, background clears',
    () async {
      var wall = 0, mono = 0;
      final bridge = BatchBridge({});
      final c = MainPageBatchController(
        bridge: bridge,
        policy: const BatchPolicy(
          maxEntries: 1,
          maxTotalCodes: 32,
          minPeriodSeconds: 20,
          maxPeriodSeconds: 86400,
          maxWindowSeconds: 600,
          minRemainingMs: 1000,
        ),
        active: () => true,
        wallMilliseconds: () => wall,
        monotonicMilliseconds: () => mono,
      );
      c.select(['a']);
      await Future<void>.delayed(Duration.zero);
      expect(c.current('a')?.value, '0000001');
      wall = 600000;
      expect(c.current('a'), null);
      expect(c.store.available(), isEmpty);
      c.foreground(false);
      expect(c.current('a'), null);
      c.dispose();
    },
  );

  test('400ms current-only accepts, no per-tick loop, new selection and resume refetch without old success delay', () async {
    var time = 0;
    final bridge = CurrentOnlyBridge({});
    final c = MainPageBatchController(
      bridge: bridge,
      policy: const BatchPolicy(
        maxEntries: 1,
        maxTotalCodes: 32,
        minPeriodSeconds: 20,
        maxPeriodSeconds: 86400,
        maxWindowSeconds: 600,
        minRemainingMs: 1,
      ),
      active: () => true,
      wallMilliseconds: () => time,
      monotonicMilliseconds: () => time,
    );
    c.select(['a']);
    await Future<void>.delayed(Duration.zero);
    expect(c.current('a')?.value, '0000001');
    expect(bridge.batches, 1);
    for (var i = 0; i < 10; i++) c.tick();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 1);
    time = 3000;
    c.select(['b']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 2);
    expect(c.current('b')?.value, '0000001');
    time = 6000;
    c.foreground(false);
    c.foreground(true);
    c.select(['a']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 3);
    time = 9000;
    c.tick();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 4);
    c.dispose();
  });

  test(
    'all omitted selection does not retry every tick as time advances',
    () async {
      var time = 0;
      final bridge = OmittedBridge({});
      final c = MainPageBatchController(
        bridge: bridge,
        policy: const BatchPolicy(
          maxEntries: 1,
          maxTotalCodes: 32,
          minPeriodSeconds: 20,
          maxPeriodSeconds: 86400,
          maxWindowSeconds: 600,
          minRemainingMs: 1,
        ),
        active: () => true,
        wallMilliseconds: () => time,
        monotonicMilliseconds: () => time,
      );
      c.select(['short']);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.batches, 1);
      for (time = 1000; time < 180000; time += 1000) {
        c.tick();
        await Future<void>.delayed(Duration.zero);
      }
      expect(bridge.batches, 1);
      expect(c.needsEntry('short'), false);
      c.dispose();
    },
  );

  test('rate failure backoff survives revision invalidate and background resume with advancing clocks', () async {
    var time = 0;
    final bridge = FailingBatchBridge({});
    final c = MainPageBatchController(
      bridge: bridge,
      policy: const BatchPolicy(
        maxEntries: 1,
        maxTotalCodes: 32,
        minPeriodSeconds: 20,
        maxPeriodSeconds: 86400,
        maxWindowSeconds: 600,
        minRemainingMs: 1,
      ),
      active: () => true,
      wallMilliseconds: () => time,
      monotonicMilliseconds: () => time,
    );
    c.select(['a']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 1);
    for (time = 1000; time < 15000; time += 1000) {
      c.invalidate();
      c.foreground(false);
      c.foreground(true);
      c.select(['a']);
      c.tick();
      await Future<void>.delayed(Duration.zero);
    }
    expect(bridge.batches, 1);
    time = 15000;
    c.tick();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 2);
    c.dispose();
  });

  test('renewal names soonest expiring held entries rather than the previous missing subset', () async {
    var time = 0;
    final bridge = HorizonBridge({});
    final c = MainPageBatchController(
      bridge: bridge,
      policy: const BatchPolicy(
        maxEntries: 2,
        maxTotalCodes: 32,
        minPeriodSeconds: 20,
        maxPeriodSeconds: 86400,
        maxWindowSeconds: 600,
        minRemainingMs: 1,
      ),
      active: () => true,
      wallMilliseconds: () => time,
      monotonicMilliseconds: () => time,
    );
    c.select(['a', 'b']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.requests.last, ['a', 'b']);
    time = 3000;
    bridge.now = 48000;
    c.select(['c', 'd']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.requests.last, ['c', 'd']);
    time = 6000;
    bridge.now = 51000;
    c.select(['a', 'b', 'c', 'd']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.requests.last, ['a', 'b']);
    expect(bridge.requests.length, 3);
    for (var i = 0; i < 10; i++) c.tick();
    await Future<void>.delayed(Duration.zero);
    expect(bridge.requests.length, 3);
    c.dispose();
  });

  testWidgets(
    'main page automatically requests a batch and shows padded generated code with copy control',
    (tester) async {
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
      final bridge = BatchBridge({
        '/v1/manage/session': SessionResponse(
          200,
          jsonEncode({'ownerId': 'owner', 'expiresAt': 9999999}),
        ),
        '/v1/manage/entries': SessionResponse(
          200,
          jsonEncode({
            'entries': [
              {
                'entry_id': 'a',
                'label': 'Test',
                'service_id': 'custom-totp',
                'capabilities': {'manage': true},
                'account_name': 'me',
                'totp': true,
              },
            ],
          }),
        ),
        '/v1/manage/active-codes': const SessionResponse(200, '{"records":[]}'),
        '/v1/manage/sources': const SessionResponse(200, '{"sources":[]}'),
        '/v1/manage/unassigned': const SessionResponse(200, '{"records":[]}'),
      });
      final controller = ReadWorkspaceController(
        bridge: bridge,
        clock: () => 45000,
      );
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: ProductShell(
            controller: controller,
            onCopyAssigned: (_) async {},
            onCopyPrivate: (_) async {},
            clock: () => 45000,
            onSignedOut: () {},
            batchPolicy: const BatchPolicy(
              maxEntries: 1,
              maxTotalCodes: 32,
              minPeriodSeconds: 20,
              maxPeriodSeconds: 86400,
              maxWindowSeconds: 600,
              minRemainingMs: 1000,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(bridge.batches, 1);
      expect(find.text('0000001'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);
      await expectLater(
        find.byType(ProductShell),
        matchesGoldenFile('goldens/mainpage-batch.png'),
      );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      await tester.tap(find.byTooltip('Copy code'));
      await tester.pump();
      expect(copied, '0000001');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('0000001'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'viewport batching advances beyond first cap and scrolls to later entries without duplicate keys',
    (tester) async {
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
      final bridge = BatchBridge({
        '/v1/manage/session': SessionResponse(
          200,
          jsonEncode({'ownerId': 'owner', 'expiresAt': 9999999}),
        ),
        '/v1/manage/entries': SessionResponse(
          200,
          jsonEncode({
            'entries': [
              for (var i = 0; i < 8; i++)
                {
                  'entry_id': 'entry$i',
                  'label': 'Test $i',
                  'service_id': 'custom-totp',
                  'capabilities': {'manage': true},
                  'account_name': 'me',
                  'totp': true,
                },
            ],
          }),
        ),
        '/v1/manage/active-codes': const SessionResponse(200, '{"records":[]}'),
        '/v1/manage/sources': const SessionResponse(200, '{"sources":[]}'),
        '/v1/manage/unassigned': const SessionResponse(200, '{"records":[]}'),
      });
      final controller = ReadWorkspaceController(
        bridge: bridge,
        clock: () => 45000,
      );
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: ProductShell(
            controller: controller,
            onCopyAssigned: (_) async {},
            onCopyPrivate: (_) async {},
            clock: () => 45000,
            onSignedOut: () {},
            batchPolicy: const BatchPolicy(
              maxEntries: 2,
              maxTotalCodes: 64,
              minPeriodSeconds: 20,
              maxPeriodSeconds: 86400,
              maxWindowSeconds: 600,
              minRemainingMs: 1000,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(bridge.batches, 1);
      expect(bridge.requests.first.length, 2);
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3100)),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.drag(find.byType(ListView).first, const Offset(0, -450));
        await tester.pump();
      }
      final all = bridge.requests.expand((ids) => ids).toSet();
      expect(all.length, greaterThan(2));
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
