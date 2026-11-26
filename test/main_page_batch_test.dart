import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:otpanda_client/main_page_batch.dart';
import 'package:otpanda_client/refresh_bar.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_batch_contract.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/main.dart';
import 'package:material_ui/material_ui.dart';

import 'product_shell_test.dart' show FakeTransport;

bool _fontsLoaded = false;

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

class FallbackBridge extends BatchBridge implements TotpManagementBridge {
  FallbackBridge(super.routes);
  int singles = 0;
  @override
  Future<SessionResponse> read(String path) async =>
      path == '/v1/manage/session'
      ? SessionResponse(
          200,
          jsonEncode({
            'ownerId': 'owner',
            'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
          }),
        )
      : super.read(path);
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    return const SessionResponse(503, '{}');
  }

  @override
  Future<String> addTotp(
    String label,
    String account,
    String secret, {
    String? catalogId,
  }) async => 'a';
  @override
  Future<SessionResponse> totpCode(String id) async {
    singles++;
    final now = DateTime.now().millisecondsSinceEpoch,
        start = now ~/ 30000 * 30;
    return SessionResponse(
      200,
      jsonEncode({
        'entryId': id,
        'code': '123456',
        'period': 30,
        'validFrom': start,
        'validUntil': start + 30,
        'serverNow': now,
      }),
    );
  }
}

class UnavailableBridge extends FakeTransport implements TotpBatchBridge {
  UnavailableBridge(super.routes);
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
        'serverNow': 45000,
        'coverageUntil': null,
        'totalCodes': 0,
        'entries': [],
        'omitted': [
          for (final id in ids) {'entryId': id, 'reason': 'unavailable'},
        ],
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

/// Cold first response (current code only), then warm responses with future
/// codes. [cold] counts how many current-only answers to give first.
class ColdThenWarmBridge extends FakeTransport implements TotpBatchBridge {
  ColdThenWarmBridge(super.routes, {this.cold = 1});
  int cold, batches = 0;
  int Function() serverNow = () => 45000;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    final now = serverNow();
    final start = now ~/ 30000 * 30;
    final count = cold > 0 ? 1 : 4;
    if (cold > 0) cold--;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': now,
        'coverageUntil': (start + 30 * count) * 1000 - 1000,
        'totalCodes': ids.length * count,
        'entries': [
          for (final id in ids)
            {
              'entryId': id,
              'period': 30,
              'digits': 7,
              'validFrom': start,
              'codes': [for (var i = 0; i < count; i++) '000000${i + 1}'],
            },
        ],
        'omitted': [],
      }),
    );
  }
}

/// Models a non-zero round trip: the server samples its clock mid-flight.
class RttBridge extends FakeTransport implements TotpBatchBridge {
  RttBridge(super.routes, this.advance, this.rtt);
  final void Function(int) advance;
  final int rtt;
  int batches = 0;
  int Function() serverNow = () => 45000;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    advance(rtt ~/ 2);
    final now = serverNow();
    advance(rtt - rtt ~/ 2);
    final start = now ~/ 30000 * 30;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': now,
        'coverageUntil': (start + 120) * 1000 - 1000,
        'totalCodes': ids.length * 4,
        'entries': [
          for (final id in ids)
            {
              'entryId': id,
              'period': 30,
              'digits': 7,
              'validFrom': start,
              'codes': [for (var i = 0; i < 4; i++) '000000${i + 1}'],
            },
        ],
        'omitted': [],
      }),
    );
  }
}

class MixedBridge extends FakeTransport implements TotpBatchBridge {
  MixedBridge(super.routes);
  int batches = 0;
  final _warm = <String, int>{};
  final coldPeriods = <int>[];
  int Function() serverNow = () => 45000;
  int warmFor(String id) => _warm[id] ?? 0;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    batches++;
    final now = serverNow();
    final entries = <Map<String, Object?>>[];
    var total = 0;
    var cover = 1 << 40;
    for (final id in ids) {
      final period = id == 'long' ? 3600 : 30;
      final start = now ~/ (period * 1000) * period;
      // 'cold' always answers with the current code only, 'long' with 3.
      final n = id == 'cold' ? 1 : 3;
      if (id == 'cold') {
        _warm[id] = (_warm[id] ?? 0) + 1;
        coldPeriods.add(now ~/ 30000);
      }
      total += n;
      final until = (start + period * n) * 1000 - 1000;
      if (until < cover) cover = until;
      entries.add({
        'entryId': id,
        'period': period,
        'digits': 7,
        'validFrom': start,
        'codes': [for (var i = 0; i < n; i++) '000000${i + 1}'],
      });
    }
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': now,
        'coverageUntil': cover,
        'totalCodes': total,
        'entries': entries,
        'omitted': [],
      }),
    );
  }
}

/// 'long' (3600 s period) always answers current-only; 'norm' answers 3 codes.
class LongColdBridge extends FakeTransport implements TotpBatchBridge {
  LongColdBridge(super.routes);
  final reqs = <(String, int)>[];
  int Function() serverNow = () => 0;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    final now = serverNow();
    final entries = <Map<String, Object?>>[];
    var cover = 1 << 40;
    for (final id in ids) {
      reqs.add((id, now));
      final period = id == 'long' ? 3600 : 30;
      final n = id == 'long' ? 1 : 3;
      final start = now ~/ (period * 1000) * period;
      cover = [
        cover,
        (start + period * n) * 1000 - 1000,
      ].reduce((a, b) => a < b ? a : b);
      entries.add({
        'entryId': id,
        'period': period,
        'digits': 7,
        'validFrom': start,
        'codes': [for (var i = 0; i < n; i++) '000000${i + 1}'],
      });
    }
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': now,
        'coverageUntil': cover,
        'totalCodes': entries.fold<int>(
          0,
          (a, e) => a + (e['codes'] as List).length,
        ),
        'entries': entries,
        'omitted': [],
      }),
    );
  }
}

MainPageBatchController _controller(
  TotpBatchBridge bridge,
  int Function() time,
) => MainPageBatchController(
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
  wallMilliseconds: time,
  monotonicMilliseconds: time,
);

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
    for (var i = 0; i < 10; i++) {
      c.tick();
    }
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
    for (var i = 0; i < 10; i++) {
      c.tick();
    }
    await Future<void>.delayed(Duration.zero);
    expect(bridge.requests.length, 3);
    c.dispose();
  });

  test('unavailable omissions retry every sixty seconds from nonzero clock without hot loop or uncaught clock fault', () async {
    var time = 100000;
    final bridge = UnavailableBridge({});
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
    for (time = 101000; time <= 280000; time += 1000) {
      c.tick();
      await Future<void>.delayed(Duration.zero);
    }
    expect(bridge.batches, 4);
    time = 0;
    expect(() => c.store.omissionRetryDue('a'), returnsNormally);
    expect(() => c.store.entryCoverageRemainingMs('a'), returnsNormally);
    c.dispose();
  });

  testWidgets(
    'main page automatically requests a batch and shows padded generated code with copy control',
    (tester) async {
      if (Platform.isLinux && !_fontsLoaded) {
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
        _fontsLoaded = true;
      }
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
      expect(find.text('No active code'), findsNothing);
      expect(find.byType(RefreshBar), findsOneWidget);
      final bar = tester.widget<RefreshBar>(find.byType(RefreshBar));
      expect(bar.periodMs, 30000);
      expect(bar.remainingMs, inInclusiveRange(1, 30000));
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/mainpage-batch.png'),
        );
      }
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      final tileBefore = tester.getRect(find.byType(Card).last);
      // Tap the identity area, not the code or a former button.
      await tester.tap(find.text('Test'));
      await tester.pump();
      expect(copied, '0000001');
      expect(find.text('Copied'), findsOneWidget);
      expect(tester.getRect(find.byType(Card).last), tileBefore);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pump();
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/tile-copied-mobile.png'),
        );
      }
      await tester.binding.setSurfaceSize(null);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('Copied'), findsNothing);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            throw PlatformException(code: 'denied');
          }
          return null;
        },
      );
      await tester.tap(find.text('Test'));
      await tester.pump();
      expect(find.text('Copied'), findsNothing);
      expect(find.text('Could not copy code.'), findsOneWidget);
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
  testWidgets('batch 503 leaves card inert and never opens a details dialog', (
    tester,
  ) async {
    final bridge = FallbackBridge({
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
    expect(find.text('0000001'), findsNothing);
    await tester.tap(find.text('Test'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(bridge.singles, 0);
    expect(find.text('123456'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
  });
  testWidgets(
    'viewport batching advances beyond first cap and scrolls to later entries without duplicate keys',
    (tester) async {
      if (Platform.isLinux && !_fontsLoaded) {
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
        _fontsLoaded = true;
      }
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

  test('cold current-only answer is warmed once in the background, then the tile changes in place at the boundary', () async {
    var time = 0;
    final bridge = ColdThenWarmBridge({})..serverNow = () => 45000 + time;
    final c = _controller(bridge, () => time);
    c.select(['a']);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.batches, 1);
    expect(c.current('a')!.value, '0000001');
    expect(c.store.hasNextCode('a'), isFalse);
    time = 3000; // minimum spacing between requests
    c.tick();
    await Future<void>.delayed(Duration.zero);
    expect(
      bridge.batches,
      2,
      reason: 'warm request without waiting for expiry',
    );
    expect(c.store.hasNextCode('a'), isTrue);
    for (var i = 0; i < 20; i++) {
      time += 500;
      c.tick();
      await Future<void>.delayed(Duration.zero);
    }
    expect(bridge.batches, 2, reason: 'no loop once warm');
    // walk across the period boundary at 60000 ms server time in 100 ms steps
    String? last = c.current('a')!.value;
    var changes = 0;
    while (45000 + time < 62000) {
      time += 100;
      c.tick();
      final v = c.current('a');
      expect(v, isNotNull, reason: 'next code is held, no blank at $time');
      if (v!.value != last) changes++;
      last = v.value;
    }
    expect(changes, 1, reason: 'one in-place change, no blank frame');
    await Future<void>.delayed(Duration.zero);
    c.dispose();
  });

  test(
    'a server that keeps answering current-only is warmed at most twice',
    () async {
      var time = 0;
      final bridge = ColdThenWarmBridge({}, cold: 99)..serverNow = () => 45000;
      final c = _controller(bridge, () => time);
      c.select(['a']);
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 30; i++) {
        time += 1000;
        c.tick();
        await Future<void>.delayed(Duration.zero);
      }
      expect(bridge.batches, lessThanOrEqualTo(4));
      expect(c.current('a'), isNotNull);
      c.dispose();
    },
  );

  testWidgets(
    'refresh bar clamps, handles zero and reduced motion, and has no semantics',
    (tester) async {
      Future<void> pump(int remaining, int period, {bool still = false}) =>
          tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: still),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 200,
                    child: RefreshBar(remainingMs: remaining, periodMs: period),
                  ),
                ),
              ),
            ),
          );
      double width() => tester.getSize(find.byType(ColoredBox).last).width;
      await pump(0, 30000);
      expect(width(), 0);
      await pump(-5, 30000);
      expect(width(), 0);
      await pump(90000, 30000, still: true);
      expect(width(), 200, reason: 'over-full is clamped to the tile width');
      await pump(15000, 30000, still: true);
      expect(width(), closeTo(100, 1));
      await pump(10000, 30000);
      final start = width();
      await tester.pump(const Duration(seconds: 5));
      expect(width(), lessThan(start), reason: 'shrinks over time');
      // The clock jumps (resume) with no frames in between: the next rebuild
      // resyncs to the new remaining time instead of lagging on the old tween.
      await pump(3000, 30000);
      await tester.pump(const Duration(seconds: 1));
      expect(width(), closeTo(200 * 2000 / 30000, 1));
      await pump(29000, 30000);
      await tester.pump(const Duration(seconds: 1));
      expect(width(), closeTo(200 * 28000 / 30000, 1));
      expect(find.byType(ExcludeSemantics), findsWidgets);
      expect(find.byType(ExcludeFocus), findsOneWidget);
      expect(find.byType(RepaintBoundary), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('non-zero round trip: blank only inside the uncertainty window, never a wrong code (known limitation, not fixed)', () async {
    var time = 0;
    final bridge = RttBridge({}, (ms) => time += ms, 400)
      ..serverNow = () => 45000 + time;
    final c = _controller(bridge, () => time);
    c.select(['a']);
    await Future<void>.delayed(Duration.zero);
    expect(time, 400);
    var blanks = 0, shown = 0;
    final seen = <String>{};
    while (45000 + time < 95000) {
      time += 50;
      c.tick();
      await Future<void>.delayed(Duration.zero);
      final v = c.current('a');
      final trueIndex = (45000 + time - 30000) ~/ 30000;
      if (v == null) {
        blanks++;
      } else {
        shown++;
        seen.add(v.value);
        expect(
          v.value,
          '000000${trueIndex + 1}',
          reason: 'never a wrong code at $time',
        );
        expect(v.remainingMs, greaterThan(0));
      }
    }
    // Two boundaries (60000, 90000). Each blank window is bounded by the
    // round-trip, 400 ms, i.e. at most ~9 steps of 50 ms. Known limitation.
    expect(
      blanks,
      greaterThan(0),
      reason: 'blank window documented, not hidden',
    );
    expect(blanks, lessThanOrEqualTo(2 * (400 ~/ 50 + 2)));
    expect(shown, greaterThan(800));
    expect(seen.length, greaterThanOrEqualTo(3));
    c.dispose();
  });

  test('minute of scroll churn stays below 24 requests per minute even against a cold-only server', () async {
    var time = 0;
    final bridge = ColdThenWarmBridge({}, cold: 9999)
      ..serverNow = () => 45000 + time;
    final c = _controller(bridge, () => time);
    var n = 0;
    while (time < 60000) {
      c.select(['e${n % 7}', 'e${(n + 1) % 7}']);
      c.tick();
      await Future<void>.delayed(Duration.zero);
      time += 100;
      n++;
    }
    expect(bridge.batches, lessThan(24));
    expect(bridge.batches, greaterThan(0));
    c.dispose();
  });

  test('warm attempts are per entry and period: a mixed set, one cold and one long period, does not starve the other', () async {
    var time = 0;
    final bridge = MixedBridge({})..serverNow = () => 45000 + time;
    final c = MainPageBatchController(
      bridge: bridge,
      policy: const BatchPolicy(
        maxEntries: 2,
        maxTotalCodes: 32,
        minPeriodSeconds: 20,
        maxPeriodSeconds: 86400,
        maxWindowSeconds: 7200,
        minRemainingMs: 1,
      ),
      active: () => true,
      wallMilliseconds: () => time,
      monotonicMilliseconds: () => time,
    );
    c.select(['long', 'cold']);
    await Future<void>.delayed(Duration.zero);
    for (var i = 0; i < 60; i++) {
      time += 1000;
      c.tick();
      await Future<void>.delayed(Duration.zero);
    }
    // 'cold' gets exactly its bounded retries while 'long' (3600 s period,
    // far outside the horizon) never spends warm quota.
    for (final p in bridge.coldPeriods.toSet()) {
      expect(
        bridge.coldPeriods.where((x) => x == p).length,
        lessThanOrEqualTo(5),
        reason: 'cold entry bounded within period $p',
      );
    }
    expect(bridge.warmFor('long'), 0);
    expect(c.current('long'), isNotNull);
    expect(bridge.batches, lessThan(24));
    c.dispose();
  });

  testWidgets(
    'ProductShell rebuilds every second, the unchanged code stays and the real bar width follows a fake clock for 10 s',
    (tester) async {
      var t = 0;
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
            batchClock: () => t,
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
      expect(find.text('0000001'), findsOneWidget);
      Element? first;
      final remainings = <int>[];
      for (var i = 0; i < 10; i++) {
        t += 1000;
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('0000001'), findsOneWidget, reason: 'code unchanged');
        final bar = tester.widget<RefreshBar>(find.byType(RefreshBar));
        remainings.add(bar.remainingMs);
        first ??= tester.element(find.byType(RefreshBar));
        expect(
          tester.element(find.byType(RefreshBar)),
          same(first),
          reason: 'same bar element, not re-created',
        );
        final full = tester.getSize(find.byType(RefreshBar)).width;
        final w = tester
            .getSize(
              find.descendant(
                of: find.byType(RefreshBar),
                matching: find.byType(ColoredBox),
              ),
            )
            .width;
        expect(
          w,
          closeTo(full * bar.remainingMs / bar.periodMs, 1.5),
          reason: 'width follows the clock at tick $i',
        );
      }
      for (var i = 1; i < remainings.length; i++) {
        expect(
          remainings[i - 1] - remainings[i],
          1000,
          reason: 'shell passes a fresh remaining every second',
        );
      }
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'prepared next code replaces directly within approved two-second window',
    (tester) async {
      if (Platform.isLinux && !_fontsLoaded) {
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
        _fontsLoaded = true;
      }
      var t = 0;
      final bridge = DelayedBatchBridge(() => t = 400, {
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
            batchClock: () => t,
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
      expect(find.text('0000001'), findsOneWidget);
      final before = tester.getSize(find.byType(Card).last).height;
      t = 15001;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Renewing code...'), findsNothing);
      expect(find.text('No active code'), findsNothing);
      expect(find.text('0000001'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsNothing);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pump();
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/batch-next-early-mobile.png'),
        );
      }
      await tester.binding.setSurfaceSize(null);
      await tester.pump();
      String? invalidCopy;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            invalidCopy = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.tap(find.text('Test'));
      await tester.pump();
      expect(invalidCopy, '0000001');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Copied'), findsOneWidget);
      expect(tester.getSize(find.byType(Card).last).height, before);
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/batch-direct-replacement.png'),
        );
      }
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Renewing code...'), findsNothing);
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/batch-direct-replacement-mobile.png'),
        );
      }
      await tester.binding.setSurfaceSize(null);
      await tester.pump(const Duration(milliseconds: 1500));
      t = 15401;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Renewing code...'), findsNothing);
      expect(find.text('0000001'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'brief stale fallback is grey updating, inert, and clears after two seconds',
    (tester) async {
      if (Platform.isLinux && !_fontsLoaded) {
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
        _fontsLoaded = true;
      }
      var t = 0;
      final bridge = BriefStaleBridge({
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
            batchClock: () => t,
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
      expect(find.text('0000001'), findsOneWidget);
      t = 15500;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Updating'), findsOneWidget);
      expect(find.text('0000001'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsNothing);
      await tester.tap(find.text('Test'));
      await tester.pump();
      expect(find.text('Copied'), findsNothing);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pump();
      if (Platform.isLinux) {
        await expectLater(
          find.byType(ProductShell),
          matchesGoldenFile('goldens/batch-stale-updating-mobile.png'),
        );
      }
      t = 18000;
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('0000001'), findsNothing);
      expect(find.text('Updating'), findsNothing);
      await tester.binding.setSurfaceSize(null);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  test('long period entering its last 15 s on a current-only server: time-gated, at most 3 s spacing, and does not touch the normal entry budget', () async {
    var time = 0;
    // 'long' period ends at server 3600000: 40 s left at t=0.
    final bridge = LongColdBridge({})..serverNow = () => 3600000 - 40000 + time;
    final c = _controller(bridge, () => time);
    c.select(['long', 'norm']);
    while (time < 39000) {
      time += 500;
      c.tick();
      await Future<void>.delayed(Duration.zero);
    }
    final long = bridge.reqs.where((r) => r.$1 == 'long').toList();
    final norm = bridge.reqs.where((r) => r.$1 == 'norm').toList();
    expect(
      norm.length,
      1,
      reason: 'normal entry: only its first fetch, budget untouched',
    );
    expect(c.current('norm'), isNotNull);
    expect(
      long.where((r) => r.$2 < 3600000 - 15000 - 3000).length,
      1,
      reason: 'no warm request before the 15 s horizon (only the first fetch)',
    );
    // Inside the horizon: spaced at least 3 s apart, so at most 5 in 15 s.
    final inside = long.where((r) => r.$2 >= 3600000 - 16000).toList();
    expect(inside.length, lessThanOrEqualTo(5));
    for (var i = 1; i < long.length; i++) {
      expect(long[i].$2 - long[i - 1].$2, greaterThanOrEqualTo(3000));
    }
    c.dispose();
  });
}

class DelayedBatchBridge extends BatchBridge {
  DelayedBatchBridge(this.arrive, super.routes);
  final void Function() arrive;
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    final response = await super.totpBatch(ids, windowSeconds: windowSeconds);
    arrive();
    return response;
  }
}

class BriefStaleBridge extends BatchBridge {
  BriefStaleBridge(super.routes);
  @override
  Future<SessionResponse> totpBatch(
    List<String> ids, {
    required int windowSeconds,
  }) async {
    if (batches > 0) return const SessionResponse(503, '{}');
    batches++;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': 45000,
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
