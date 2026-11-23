import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  testWidgets('entry creation validates label and cancel does not create', (
    tester,
  ) async {
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add entry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create entry'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a service or label.'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).first,
      'Fictional new entry',
    );
    await tester.enterText(find.byType(TextFormField).last, 'fictional login');
    await tester.tap(find.text('Create entry'));
    await tester.pumpAndSettle();
    expect(find.text('Fictional new entry'), findsOneWidget);
    await tester.tap(find.text('Add entry'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Discard me');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard me'), findsNothing);
  });
  testWidgets(
    'shared entries have no edit/delete and deletion requires confirmation',
    (tester) async {
      await tester.pumpWidget(const OTPandaApp());
      await tester.tap(find.text('Entries'));
      await tester.pumpAndSettle();
      expect(find.text('Edit entry'), findsNWidgets(2));
      expect(find.textContaining('Only the owner'), findsOneWidget);
      await tester.tap(find.text('Delete entry').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Northstar'), findsOneWidget);
      await tester.tap(find.text('Delete entry').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete entry'));
      await tester.pumpAndSettle();
      expect(find.text('Northstar'), findsNothing);
      await tester.tap(find.text('Codes'));
      await tester.pumpAndSettle();
      expect(find.text('123 456'), findsNothing);
    },
  );
  testWidgets('entry edit keeps code bound to the same entry', (tester) async {
    await tester.pumpWidget(const OTPandaApp());
    await tester.tap(find.text('Entries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit entry').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Renamed service');
    await tester.enterText(find.byType(TextFormField).last, 'changed-login');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.text('Northstar'), findsNothing);
    expect(find.text('Renamed service'), findsOneWidget);
    await tester.tap(find.text('Codes'));
    await tester.pumpAndSettle();
    expect(find.text('123 456'), findsOneWidget);
    expect(find.text('changed-login'), findsOneWidget);
  });
}
