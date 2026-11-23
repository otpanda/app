import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/account_preview.dart';

void main() {
  testWidgets(
    'account setup opens with truthful limits and no credential fields',
    (tester) async {
      await tester.pumpWidget(const OTPandaApp());
      await tester.tap(find.byTooltip('Account & security'));
      await tester.pumpAndSettle();
      expect(find.text('Account & security'), findsOneWidget);
      expect(find.textContaining('No account is signed in'), findsOneWidget);
      expect(find.text('Sign-in is not connected yet'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Your codes'), findsOneWidget);
    },
  );
  testWidgets(
    'sample readiness and last-option warning do not claim enrollment',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: AccountSecurityPreview()),
      );
      expect(find.text('At risk of losing access'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Include a sample passkey'),
        250,
      );
      await tester.tap(find.text('Include a sample passkey'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('One example recovery option'),
        -250,
      );
      expect(find.text('One example recovery option'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Include a sample passkey'),
        250,
      );
      await tester.tap(find.text('Include a sample passkey'));
      await tester.pumpAndSettle();
      expect(find.text('No recovery option left'), findsOneWidget);
      await tester.tap(find.text('Keep option'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isTrue,
      );
      await tester.tap(find.text('Include a sample passkey'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove in preview'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isFalse,
      );
    },
  );
  testWidgets('small screen security preview and warning stay usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: AccountSecurityPreview()));
    await tester.scrollUntilVisible(
      find.text('Include a sample Android device'),
      200,
    );
    await tester.ensureVisible(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Keep option'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
