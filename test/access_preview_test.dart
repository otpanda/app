import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  testWidgets(
    'app revocation is confirmed, separate from people, and survives navigation',
    (tester) async {
      await tester.pumpWidget(const OTPandaApp());
      await tester.tap(find.text('Temporary demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Access'));
      await tester.pumpAndSettle();
      expect(
        find.text('Read-only codes · Automation not allowed'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Revoke app access'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke app access'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Revoked in this demo'), findsNothing);
      await tester.tap(find.text('Revoke app access'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Revoke app access'));
      await tester.pumpAndSettle();
      expect(find.text('Revoked in this demo'), findsOneWidget);
      expect(
        find.text('Read-only codes · Automation not allowed'),
        findsOneWidget,
      );
      await tester.tap(find.text('Codes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Access'));
      await tester.pumpAndSettle();
      expect(find.text('Revoked in this demo'), findsOneWidget);
    },
  );
  testWidgets('small access confirmation is dismissible without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Temporary demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Access'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Revoke app access'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke app access'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Revoked in this demo'), findsNothing);
  });
}
