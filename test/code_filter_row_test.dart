import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/code_filter_row.dart';

void main() {
  testWidgets('overflow row and dialog use the same selection', (t) async {
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
      await File('/downloads/code-filter-row-390.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await t.tap(find.byKey(const Key('code-filter-more')));
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilterChip>(find.byKey(const ValueKey('dialog-filter-work')))
          .selected,
      true,
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
