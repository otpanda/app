import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_navigation.dart';

void main() {
  test(
    'history controller retains pages until explicit session clear',
    () {
      final h = NativeNavigationHistory();
      h.navigate('settings');
      h.navigate('about');
      expect(h.route, 'about');
      h.back();
      expect(h.route, 'settings');
      h.clear();
      expect(h.route, 'codes');
      expect(h.atRoot, isTrue);
    },
  );
  testWidgets(
    'native Back walks account history, duplicates do not add steps, root may exit',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: NativeNavigation(
            builder: (context, route, navigate) => Scaffold(
              body: Column(
                children: [
                  Text('page:$route'),
                  TextButton(
                    onPressed: () => navigate('codes'),
                    child: const Text('Codes'),
                  ),
                  TextButton(
                    onPressed: () => navigate('settings'),
                    child: const Text('Settings'),
                  ),
                  TextButton(
                    onPressed: () => navigate('about'),
                    child: const Text('About'),
                  ),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const AlertDialog(content: Text('dialog')),
                    ),
                    child: const Text('Dialog'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();
      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();
      await t.tap(find.text('About'));
      await t.pumpAndSettle();
      await t.tap(find.text('Codes'));
      await t.pumpAndSettle();
      expect(find.text('page:codes'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('page:about'), findsOneWidget);
      await t.tap(find.text('Dialog'));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('dialog'), findsNothing);
      expect(find.text('page:about'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('page:settings'), findsOneWidget);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(find.text('page:codes'), findsOneWidget);
      expect(
        t.widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope)).canPop,
        isTrue,
      );
    },
  );
}
