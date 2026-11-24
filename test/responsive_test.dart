import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  testWidgets('desktop uses side navigation, phone uses bottom navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Temporary demo'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(5));
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(320, 400);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('small phone dialog remains dismissible without assignment', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Temporary demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unassigned'));
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(
        find.ancestor(
          of: find.text('Choose account'),
          matching: find.byType(TextButton),
        ),
      ),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose account'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close dialog'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Choose account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
