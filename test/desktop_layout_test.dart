import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  testWidgets('desktop navigation labels fit a single line', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OTPandaApp());
    for (final label in [
      'Codes',
      'Sources',
      'Access',
      'Unassigned',
      'Entries',
    ]) {
      final finder = find.descendant(
        of: find.byType(ListTile),
        matching: find.text(label),
      );
      final paragraph = tester.renderObject<RenderParagraph>(finder);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: label.length),
      );
      expect(boxes.map((box) => box.top).toSet().length, 1, reason: label);
    }
    expect(tester.takeException(), isNull);
  });
}
