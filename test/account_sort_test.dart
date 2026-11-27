import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/account_sort.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;

void main() {
  test('pins partition every sort, exact weighted scores retained, dates unknown last', () {
    const a = [
      AccountSortValues(
        id: 'a',
        name: 'Zulu',
        pinned: false,
        score: 8.5,
        createdAt: 3,
        lastUsedAt: 7,
      ),
      AccountSortValues(
        id: 'b',
        name: 'Alpha',
        pinned: true,
        score: 0,
        createdAt: 1,
      ),
      AccountSortValues(
        id: 'c',
        name: 'Beta',
        pinned: false,
        score: 9.1,
        createdAt: 2,
        lastUsedAt: 8,
      ),
      AccountSortValues(id: 'd', name: 'Delta', pinned: false),
    ];
    expect(sortAccounts(a, AccountSort.frequentlyUsed), ['b', 'c', 'a', 'd']);
    expect(sortAccounts(a, AccountSort.newestFirst), ['b', 'a', 'c', 'd']);
    expect(sortAccounts(a, AccountSort.oldestFirst), ['b', 'c', 'a', 'd']);
    expect(sortAccounts(a, AccountSort.nameAscending), ['b', 'c', 'd', 'a']);
    expect(sortAccounts(a, AccountSort.nameDescending), ['b', 'a', 'd', 'c']);
    expect(sortAccounts(a, AccountSort.lastUsed), ['b', 'c', 'a', 'd']);
  });
  for (final size in [const Size(1280, 800), const Size(360, 800)]) {
    testWidgets('sort dialog bounded and readable at ${size.width}', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        for (final pair in [
          ('Figtree', 'Figtree-400.ttf'),
          (
            'MaterialIcons',
            '${Platform.environment['FLUTTER_ROOT'] ?? '/downloads/otpanda/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
          ('BricolageGrotesque', 'BricolageGrotesque-700.ttf'),
        ]) {
          final font = FontLoader(pair.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(
                  File(
                    pair.$2.startsWith('/')
                        ? pair.$2
                        : 'assets/fonts/${pair.$2}',
                  ).readAsBytesSync(),
                ),
              ),
            );
          await font.load();
        }
      });
      var order = AccountSort.frequentlyUsed;
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: Scaffold(
            body: Center(
              child: AccountSortButton(
                value: order,
                onChanged: (value) => order = value,
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('account-sort-button')));
      await t.pumpAndSettle();
      final dialog = find.byKey(const Key('account-sort-dialog'));
      final surface = find
          .descendant(of: dialog, matching: find.byType(Material))
          .first;
      expect(t.getSize(surface).width, lessThanOrEqualTo(460));
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final boundary = t.renderObject<RenderRepaintBoundary>(
          find
              .ancestor(of: surface, matching: find.byType(RepaintBoundary))
              .first,
        );
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${Platform.environment['SCREENSHOT_DIR'] ?? Directory.systemTemp.path}/account-sort-${size.width.toInt()}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await t.tap(find.text('Last used'));
      await t.pumpAndSettle();
      expect(order, AccountSort.lastUsed);
      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('account-sort-dialog')), findsNothing);
    });
  }
}
