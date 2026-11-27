import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/revealed_filter_list.dart';
import 'package:otpanda_client/pull_to_refresh.dart';

void main() {
  testWidgets(
    'mobile reverse scroll reveals; forward scroll hides; refresh still works',
    (t) async {
      var refreshed = 0;
      final scroll = ScrollController(initialScrollOffset: 300);
      addTearDown(scroll.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: RevealedFilterList(
              mobile: true,
              filters: const Text('Filter row'),
              child: PullToRefresh(
                onRefresh: () async {
                  refreshed++;
                },
                child: ListView.builder(
                  controller: scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: 50,
                  itemBuilder: (context, index) =>
                      SizedBox(height: 60, child: Text('Account $index')),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Filter row'), findsNothing);
      await t.drag(find.byType(ListView), const Offset(0, 120));
      await t.pumpAndSettle();
      expect(find.text('Filter row'), findsOneWidget);
      expect(refreshed, 0);
      await t.drag(find.byType(ListView), const Offset(0, -120));
      await t.pumpAndSettle();
      expect(find.text('Filter row'), findsNothing);
      scroll.jumpTo(0);
      await t.pumpAndSettle();
      expect(find.text('Filter row'), findsNothing);
      await t.drag(find.byType(ListView), const Offset(0, 400));
      await t.pumpAndSettle();
      expect(refreshed, 1);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('desktop row always visible', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RevealedFilterList(
            mobile: false,
            filters: Text('Filter row'),
            child: SingleChildScrollView(child: SizedBox(height: 1600)),
          ),
        ),
      ),
    );
    expect(find.text('Filter row'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
