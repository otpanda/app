import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  for (final size in const [Size(320, 640), Size(1280, 800)]) {
    testWidgets('empty codes state fits $size and actions work', (t) async {
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      await t.pumpWidget(
        const MaterialApp(home: ClientHome(emptyFixture: true)),
      );
      expect(find.text('No codes yet'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('Add an entry'));
      await t.pumpAndSettle();
      expect(find.text('All your configured entries.'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
