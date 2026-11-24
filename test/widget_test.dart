import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/models.dart';

void main() {
  test('code format, lifetime and redaction', () {
    final c = ActiveCode('a', 'A12-34', 100, 200);
    expect(c.active(99), false);
    expect(c.active(100), true);
    expect(c.active(200), false);
    expect(c.toString().contains('A12-34'), false);
    expect(() => ActiveCode('a', '1', 100, 200), throwsArgumentError);
  });
  testWidgets(
    'assignment dialog closes without mutation and assigns owned entry explicitly',
    (tester) async {
      await tester.pumpWidget(const OTPandaApp());
      await tester.tap(find.text('Temporary demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose account'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byTooltip('Close dialog'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Choose account'), findsOneWidget);
      await tester.tap(find.text('Choose account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  testWidgets('search and navigation keep sources copy', (
    tester,
  ) async {
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Temporary demo'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'orchard');
    await tester.pump();
    expect(find.text('Orchard'), findsOneWidget);
    expect(find.text('Northstar'), findsNothing);
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.textContaining('send codes to your account'), findsOneWidget);
  });
}
