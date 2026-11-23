import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  testWidgets('source revoke requires confirmation and survives navigation', (
    tester,
  ) async {
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke source'), findsOneWidget);
    await tester.tap(find.text('Revoke source'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke source'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Revoked in this demo'), findsOneWidget);
    expect(find.text('Revoke source'), findsNothing);
    await tester.tap(find.text('Codes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Revoked in this demo'), findsOneWidget);
  });
}
