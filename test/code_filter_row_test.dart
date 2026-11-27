import 'dart:io';

import 'package:flutter/services.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/code_filter_row.dart';

void main() {
  testWidgets('all fitting chips have no overflow, overflow is compact', (
    t,
  ) async {
    await t.runAsync(() async {
      final font = FontLoader('Figtree');
      for (final weight in ['400', '500', '600', '700']) {
        font.addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/Figtree-$weight.ttf').readAsBytesSync(),
            ),
          ),
        );
      }
      await font.load();
    });
    for (final width in [250.0, 390.0, 1280.0]) {
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: CodeFilterRow(
                  choices: const [
                    CodeFilterChoice('mine', 'Mine'),
                    CodeFilterChoice('shared', 'Shared'),
                  ],
                  selected: const {},
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('code-filter-more')), findsNothing);
      expect(find.byType(FilterChip), findsNWidgets(2));
      expect(t.takeException(), isNull);
      if (width == 390) {
        await t.runAsync(() async {
          final image = await t
              .renderObject<RenderRepaintBoundary>(
                find.byType(RepaintBoundary).first,
              )
              .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Platform.environment['SCREENSHOT_DIR'] ?? Directory.systemTemp.path}/code-filter-all-fit-390.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await t.pumpWidget(
      MaterialApp(
        theme: otpandaTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: CodeFilterRow(
              choices: const [
                CodeFilterChoice('mine', 'Mine'),
                CodeFilterChoice('shared', 'Shared'),
                CodeFilterChoice('long', 'Very long tag'),
              ],
              selected: const {},
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('code-filter-more')), findsOneWidget);
    expect(
      t.getSize(find.byKey(const Key('code-filter-more'))).width,
      lessThan(130),
    );
    expect(t.takeException(), isNull);
  });
  testWidgets('overflow row and dialog use the same selection', (t) async {
    t.view.physicalSize = const Size(390, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var selected = <String>{'work'};
    const choices = [
      CodeFilterChoice('mine', 'Mine'),
      CodeFilterChoice('shared', 'Shared'),
      CodeFilterChoice('work', 'Work'),
      CodeFilterChoice('family', 'Family'),
      CodeFilterChoice('long', 'A very long personal tag label'),
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: otpandaTheme(),
        home: Scaffold(
          body: RepaintBoundary(
            key: const Key('pixels'),
            child: ColoredBox(
              color: Colors.white,
              child: Column(
                children: [
                  StatefulBuilder(
                    builder: (context, update) => CodeFilterRow(
                      choices: choices,
                      selected: selected,
                      onChanged: (value) => update(() => selected = value),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.byKey(const ValueKey('filter-work')), findsOneWidget);
    expect(find.byKey(const Key('code-filter-more')), findsOneWidget);
    final boundary = t.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('pixels')),
    );
    await t.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${Platform.environment['SCREENSHOT_DIR'] ?? Directory.systemTemp.path}/code-filter-row-390.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await t.tap(find.byKey(const Key('code-filter-more')));
    await t.pumpAndSettle();
    expect(find.text('Match all selected tags'), findsNothing);
    expect(
      t
          .widget<FilterChip>(find.byKey(const ValueKey('dialog-filter-work')))
          .selected,
      true,
    );
    expect(
      t.getTopLeft(find.byKey(const ValueKey('dialog-filter-work'))).dy,
      lessThanOrEqualTo(
        t.getTopLeft(find.byKey(const ValueKey('dialog-filter-mine'))).dy,
      ),
    );
    expect(
      t.getTopLeft(find.byKey(const ValueKey('dialog-filter-work'))).dx,
      lessThan(
        t.getTopLeft(find.byKey(const ValueKey('dialog-filter-mine'))).dx,
      ),
    );
    await t.tap(find.byKey(const ValueKey('dialog-filter-family')));
    await t.pumpAndSettle();
    expect(selected, containsAll(['work', 'family']));
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.byKey(const Key('code-filter-more')));
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilterChip>(
            find.byKey(const ValueKey('dialog-filter-family')),
          )
          .selected,
      true,
    );
    await t.tap(find.text('Clear all'));
    await t.pumpAndSettle();
    expect(selected, isEmpty);
  });
}
