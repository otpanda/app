import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/display_settings.dart';
import 'package:otpanda_client/organization_contract.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/theme_choice.dart';
import 'package:otpanda_client/theme_controller.dart';
import 'package:otpanda_client/tile_display_preference.dart';

import 'package:otpanda_client/totp_enrollment.dart';

import 'totp_enrollment_test.dart' show Bridge;
import 'product_shell_test.dart' show FakeTransport, routes;
import 'theme_test.dart' show MemTheme, MemTiles;

/// Screenshot harness, off in normal runs. Set THEME_SHOTS=/output/dir to
/// render light and dark screens for visual review.
final out = Platform.environment['THEME_SHOTS'];

Future<void> fonts(WidgetTester t) => t.runAsync(() async {
  final flutter =
      Platform.environment['FLUTTER_ROOT'] ?? '/home/sandbox/flutter';
  for (final pair in [
    ('Figtree', 'assets/fonts/Figtree-400.ttf'),
    ('BricolageGrotesque', 'assets/fonts/BricolageGrotesque-700.ttf'),
    (
      'MaterialIcons',
      '$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ),
    ('CodeMono', 'assets/fonts/CodeMono-Regular.ttf'),
  ]) {
    final f = FontLoader(pair.$1)
      ..addFont(
        Future.value(ByteData.sublistView(File(pair.$2).readAsBytesSync())),
      );
    await f.load();
  }
});

Future<void> shot(WidgetTester t, String name) => t.runAsync(() async {
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('shot-root')),
  );
  final image = await boundary.toImage();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$out/$name.png').writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
});

void main() {
  if (out == null) {
    test('theme screenshots skipped (set THEME_SHOTS)', () {}, skip: true);
    return;
  }
  for (final choice in [ThemeChoice.light, ThemeChoice.dark]) {
    for (final width in [390.0, 1280.0]) {
      testWidgets('shell ${choice.name} $width', (t) async {
        t.view.physicalSize = Size(width, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await fonts(t);
        final bridge = FakeTransport(
          routes(
            entries: [
              for (var i = 0; i < 12; i++)
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
          ..reconcileEntries([for (var i = 0; i < 12; i++) 'e$i'])
          ..createTag('work', 'Work')
          ..setTags('e0', {'work'})
          ..setPinned('e0', true);
        final theme = ThemeController(MemTheme());
        await theme.set(choice);
        await t.pumpWidget(
          RepaintBoundary(
            key: const Key('shot-root'),
            child: ThemeScope(
              controller: theme,
              builder: (context, light, dark, mode) => MaterialApp(
                theme: light,
                darkTheme: dark,
                themeMode: mode,
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
            ),
          ),
        );
        await t.pumpAndSettle();
        await shot(t, 'shell-${choice.name}-${width.toInt()}');
        // Mobile filters reveal only after scrolling toward the top.
        if (width <= 700) {
          await t.drag(find.byType(ListView).first, const Offset(0, -400));
          await t.pumpAndSettle();
          await t.drag(find.byType(ListView).first, const Offset(0, 80));
          await t.pumpAndSettle();
        }
        // Sort dialog.
        await t.tap(find.byKey(const Key('account-sort-button')));
        await t.pumpAndSettle();
        await shot(t, 'sort-${choice.name}-${width.toInt()}');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        // Selection state: checkbox on desktop, long press on mobile.
        if (width > 700) {
          await t.tap(find.byType(Checkbox).at(3));
        } else {
          await t.longPress(find.text('GitHub').last);
        }
        await t.pumpAndSettle();
        await shot(t, 'selected-${choice.name}-${width.toInt()}');
        // Tag filter chip pressed.
        await t.tap(find.text('Add tags').first, warnIfMissed: false);
        await t.pumpAndSettle();
        await shot(t, 'tagdialog-${choice.name}-${width.toInt()}');
      });
    }
    testWidgets('authenticator enrollment ${choice.name}', (t) async {
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await fonts(t);
      final theme = ThemeController(MemTheme());
      await theme.set(choice);
      addTearDown(theme.dispose);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shot-root'),
          child: ThemeScope(
            controller: theme,
            builder: (context, light, dark, mode) => MaterialApp(
              theme: light,
              darkTheme: dark,
              themeMode: mode,
              home: Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: FilledButton(
                      onPressed: () => addTotpDialog(
                        context,
                        Bridge(),
                        camera: (onText, onError) => const SizedBox(
                          height: 200,
                          child: Center(child: Icon(Icons.camera_alt_outlined)),
                        ),
                      ),
                      child: const Text('Add authenticator'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Add authenticator'));
      await t.pumpAndSettle();
      await shot(t, 'enrollment-camera-${choice.name}');
      await t.tap(find.text('Enter key manually'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await shot(t, 'enrollment-manual-${choice.name}');
    });
    testWidgets('settings and dialog ${choice.name}', (t) async {
      t.view.physicalSize = const Size(560, 760);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await fonts(t);
      final theme = ThemeController(MemTheme());
      await theme.set(choice);
      await t.pumpWidget(
        RepaintBoundary(
          key: const Key('shot-root'),
          child: ThemeScope(
            controller: theme,
            builder: (context, light, dark, mode) => MaterialApp(
              theme: light,
              darkTheme: dark,
              themeMode: mode,
              home: Scaffold(
                appBar: AppBar(title: const Text('Display')),
                body: Builder(
                  builder: (context) => ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      DisplaySettings(
                        preference: TileDisplayPreference(MemTiles()),
                        theme: theme,
                      ),
                      FilledButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Revoke app access?'),
                            content: const TextField(
                              decoration: InputDecoration(hintText: 'Name'),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () {},
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () {},
                                child: const Text('Revoke'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('Open dialog'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await shot(t, 'settings-${choice.name}');
      await t.tap(find.text('Open dialog'));
      await t.pumpAndSettle();
      await shot(t, 'dialog-${choice.name}');
    });
  }
}
