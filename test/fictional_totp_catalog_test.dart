import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';

void main() {
  testWidgets(
    'fictional catalog opens selected entry and discards code on close',
    (t) async {
      await t.pumpWidget(const OTPandaApp());
      await t.enterText(find.byType(TextField), 'orchard');
      await t.pump();
      await t.ensureVisible(find.text('Preview fictional generated code'));
      await t.pumpAndSettle();
      await t.tap(find.text('Preview fictional generated code'));
      await t.pumpAndSettle();
      expect(find.text('Fictional entry preview'), findsOneWidget);
      expect(find.text('Orchard'), findsNWidgets(2));
      expect(find.text('------'), findsOneWidget);
      expect(
        find.textContaining('No account, seed or live service'),
        findsOneWidget,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Load fictional code'));
      await t.pump();
      await t.pump();
      expect(find.text('001 234'), findsOneWidget);
      expect(find.byTooltip('Copy fictional code'), findsNothing);
      await t.tap(find.byTooltip('Close generated-code preview'));
      await t.pumpAndSettle();
      expect(find.text('001 234'), findsNothing);
      await t.ensureVisible(find.text('Preview fictional generated code'));
      await t.pumpAndSettle();
      await t.tap(find.text('Preview fictional generated code'));
      await t.pumpAndSettle();
      expect(find.text('------'), findsOneWidget);
      expect(find.text('001 234'), findsNothing);
      await t.tap(find.byTooltip('Close generated-code preview'));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'fixture controls require explicit opt in, not manage permission',
    (t) async {
      await t.pumpWidget(const MaterialApp(home: ClientHome()));
      expect(find.text('Preview fictional generated code'), findsNothing);
      await t.pumpWidget(const OTPandaApp());
      await t.enterText(find.byType(TextField), 'harbor');
      await t.pump();
      expect(find.text('Harbor'), findsOneWidget);
      expect(find.text('Preview fictional generated code'), findsOneWidget);
      await t.ensureVisible(find.text('Preview fictional generated code'));
      await t.pumpAndSettle();
      await t.tap(find.text('Preview fictional generated code'));
      await t.pumpAndSettle();
      expect(find.text('Fictional entry preview'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('small catalog dialog fits and platform pop dismisses preview', (
    t,
  ) async {
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.view.physicalSize = const Size(320, 700);
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(const OTPandaApp());
    await t.enterText(find.byType(TextField), 'orchard');
    await t.pump();
    await t.ensureVisible(find.text('Preview fictional generated code'));
    await t.ensureVisible(find.text('Preview fictional generated code'));
    await t.pumpAndSettle();
    await t.tap(find.text('Preview fictional generated code'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Load fictional code'));
    await t.pumpAndSettle();
    await t.tap(find.text('Load fictional code'));
    await t.pump();
    await t.pump();
    expect(t.takeException(), null);
    expect(find.text('001 234'), findsOneWidget);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.text('001 234'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
