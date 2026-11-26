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
        'coverageUntil': 600000,
        'totalCodes': 20,
        'entries': [
          {
            'entryId': 'a',
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
      await expectLater(find.byType(ProductShell),matchesGoldenFile('goldens/mainpage-batch.png'));
      String? copied;tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,(call)async{if(call.method=='Clipboard.setData')copied=(call.arguments as Map)['text'] as String;return null;});
      await tester.tap(find.byTooltip('Copy code'));await tester.pump();expect(copied,'0000001');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);await tester.pump();expect(find.text('0000001'),findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);await tester.pump();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
