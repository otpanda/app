import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/organization_contract.dart';
import 'package:otpanda_client/read_workspace_controller.dart';

import 'product_shell_test.dart' show FakeTransport, routes;

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('integrated unified grid at $width', (t) async {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        for (final pair in [
          ('Figtree', 'assets/fonts/Figtree-400.ttf'),
          ('BricolageGrotesque', 'assets/fonts/BricolageGrotesque-700.ttf'),
          (
            'MaterialIcons',
            '/downloads/otpanda/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
          ('CodeMono', 'assets/fonts/CodeMono-Regular.ttf'),
        ]) {
          final f = FontLoader(pair.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(pair.$2).readAsBytesSync()),
              ),
            );
          await f.load();
        }
      });
      final bridge = FakeTransport(
        routes(
          entries: [
            for (var i = 0; i < 6; i++)
              {
                'entry_id': 'e$i',
                'service_name': [
                  'GitHub',
                  'Amazon Web Services',
                  'Cloudflare',
                ][i % 3],
                'account_name': 'abrahammurciano',
                'capabilities': {'manage': i != 5},
                'createdAt': 100 + i,
              },
          ],
          codes: [
            for (var i = 0; i < 3; i++)
              {
                'entryId': 'e$i',
                'code': '12345$i',
                'receivedAt': 999999,
                'expiresAt': 1100000,
              },
          ],
        ),
      );
      final controller = ReadWorkspaceController(
        bridge: bridge,
        clock: () => 1000000,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      final org = OrganizationStore()
        ..reconcileEntries([for (var i = 0; i < 6; i++) 'e$i'])
        ..createTag('work', 'Work')
        ..setTags('e0', {'work'})
        ..setPinned('e0', true);
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: ProductShell(
            controller: controller,
            organization: org,
            showTileTags: true,
            onCopyAssigned: (_) async {},
            onCopyPrivate: (_) async {},
            clock: () => 1000000,
            onSignedOut: () {},
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Accounts'), findsOneWidget);
      expect(find.text('New arrivals'), findsOneWidget);
      await t.runAsync(() async {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/downloads/unified-integrated-${width.toInt()}.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      if (width > 700) {
        expect(find.byType(Checkbox), findsWidgets);
      } else {
        expect(find.byType(Checkbox), findsNothing);
      }
    });
  }
}
