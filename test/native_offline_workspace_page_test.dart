import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/native/native_offline_workspace_page.dart';
import 'package:otpanda_client/offline_totp.dart';
import 'package:otpanda_client/offline_totp/native_offline_workspace_runtime.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';
import 'package:otpanda_client/session_contract.dart';

import 'offline_totp/fake_seed_custody.dart';

void main() {
  setUpAll(() async {
    for (final family in ['Figtree', 'BricolageGrotesque', 'MaterialIcons']) {
      final loader = FontLoader(family);
      final paths = family == 'MaterialIcons'
          ? [
              '${Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ]
          : (family == 'Figtree' ? [400, 500, 600, 700] : [700, 800])
                .map((w) => 'assets/fonts/$family-$w.ttf')
                .toList();
      for (final path in paths) {
        loader.addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
        );
      }
      await loader.load();
    }
  });
  testWidgets(
    'cold local page has no session, generates own codes, expires shared cache, and hides on lock',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('offline-page-');
      final keys = FakeSecretStore(), custody = FakeSeedCustody();
      var now = 59000, reconnects = 0;
      final runtime = NativeOfflineWorkspaceRuntime(clock: () => now);
      Future<void> open(bool fresh) => runtime.open(
        keys: keys,
        custody: custody,
        namespace: 'workspace',
        path: '${dir.path}/db',
        owner: 'owner',
        install: 'install',
        epoch: 0,
        admittedFreshWorkspace: fresh,
        stillLocallyUnlocked: () => true,
      );
      await tester.runAsync(() async {
        await custody.provision(
          ownerId: 'owner',
          entryId: 'entry',
          seedVersion: 1,
          algorithm: OtpAlgorithm.sha1,
          digits: 8,
          period: 30,
          seed: Uint8List.fromList('12345678901234567890'.codeUnits),
          epoch: 0,
        );
        await open(true);
        runtime.publishAuthenticated(
          NativeWorkspaceSnapshot(
            ownerId: 'owner',
            installId: 'install',
            epoch: 0,
            savedAtMs: now,
            entries: [
              const ManagedEntry('entry', 'Local service', 'me', true, true),
              const ManagedEntry(
                'shared',
                'Shared service',
                'them',
                false,
                true,
              ),
            ],
            codes: [
              ReceivedCode.fromJson({
                'entryId': 'shared',
                'code': '654321',
                'receivedAt': now,
                'expiresAt': 60000,
              }),
            ],
            sources: [],
            unassigned: [],
          ),
        );
        runtime.lock();
        await open(false);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        runtime.dispose();
        dir.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildOtpandaTheme(Brightness.light),
          home: NativeOfflineWorkspacePage(
            runtime: runtime,
            clock: () => now,
            onReconnect: () => reconnects++,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('94287082'), findsOneWidget);
      expect(find.text('654321'), findsOneWidget);
      expect(find.textContaining('Offline.'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('native_offline_cold.png'),
      );
      await tester.tap(find.byTooltip('Reconnect'));
      expect(reconnects, 1);
      await tester.runAsync(() async {
        now = 60000;
        await runtime.refreshLocalCodes();
      });
      await tester.pump();
      expect(find.text('654321'), findsNothing);
      expect(find.text('Connect to refresh this code'), findsOneWidget);
      runtime.lock();
      await tester.pump();
      expect(find.text('Local service'), findsNothing);
      expect(find.text('Local codes are locked.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
