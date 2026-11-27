import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/branding.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';

import 'product_shell_test.dart' show FakeTransport, routes;

void main() {
  setUpAll(() async {
    for (final family in [
      'Figtree',
      'BricolageGrotesque',
      'MaterialIcons',
      'CodeMono',
    ]) {
      final loader = FontLoader(family);
      final files = family == 'CodeMono'
          ? ['assets/fonts/CodeMono-Regular.ttf']
          : family == 'MaterialIcons'
          ? [
              '${Platform.environment['FLUTTER_ROOT'] ?? '/downloads/otpanda/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ]
          : (family == 'Figtree' ? [400, 500, 600, 700] : [700, 800])
                .map((w) => 'assets/fonts/$family-$w.ttf')
                .toList();
      for (final file in files) {
        loader.addFont(
          Future.value(ByteData.sublistView(File(file).readAsBytesSync())),
        );
      }
      await loader.load();
    }
  });
  for (final width in [390.0, 1280.0]) {
    for (final web in [false, true]) {
      testWidgets(
        '${web ? 'web' : 'native'} header $width uses intended branding',
        (t) async {
          t.view.physicalSize = Size(width, 850);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          final tr = FakeTransport(
            routes(
              entries: [
                {
                  'entry_id': 'a',
                  'service_name': 'GitHub',
                  'account_name': 'abraham@example.com',
                  'capabilities': {'manage': true},
                },
              ],
            ),
          );
          final c = ReadWorkspaceController(bridge: tr, clock: () => 1000000);
          addTearDown(c.dispose);
          await c.refresh();
          await t.pumpWidget(
            RepaintBoundary(
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: otpandaTheme(),
                home: ProductShell(
                  controller: c,
                  onCopyAssigned: (_) async {},
                  onCopyPrivate: (_) async {},
                  clock: () => 1000000,
                  onSignedOut: () {},
                  showHeaderBrand: web,
                ),
              ),
            ),
          );
          await t.runAsync(() async {
            await precacheImage(
              MemoryImage(ottyImage),
              t.element(find.byType(ProductShell)),
            );
          });
          await t.pumpAndSettle();
          expect(
            find.byKey(const Key('web-header-brand')),
            web ? findsOneWidget : findsNothing,
          );
          if (web) {
            final image = t.widget<Image>(
              find.byKey(const Key('web-header-brand')),
            );
            expect((image.image as MemoryImage).bytes, same(ottyImage));
          }
          expect(find.byType(TextField), findsOneWidget);
          expect(t.takeException(), isNull);
          final output = Platform.environment['HEADER_SHOTS'];
          if (output != null) {
            final b = t.renderObject<RenderRepaintBoundary>(
              find.byType(RepaintBoundary).first,
            );
            await t.runAsync(() async {
              final image = await b.toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File('$output/${web ? 'web' : 'native'}-${width.toInt()}.png')
                  .writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        },
      );
    }
  }
}
