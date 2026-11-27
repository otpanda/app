import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/display_settings.dart';
import 'package:otpanda_client/tile_display_preference.dart';

class Store implements TileDisplayStore {
  bool value = false, fail = false;
  @override
  Future<bool> showTags() async => value;
  @override
  Future<void> setShowTags(bool enabled) async {
    if (fail) throw StateError('unavailable');
    value = enabled;
  }
}

void main() {
  testWidgets('off by default, persists only after success', (t) async {
    final store = Store();
    final p = TileDisplayPreference(store);
    var changes = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DisplaySettings(preference: p, onChanged: () => changes++),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      t.widget<SwitchListTile>(find.byKey(const Key('show-tile-tags'))).value,
      false,
    );
    await t.tap(find.byKey(const Key('show-tile-tags')));
    await t.pumpAndSettle();
    expect(p.showTags, true);
    expect(store.value, true);
    expect(changes, 1);
    store.fail = true;
    await t.tap(find.byKey(const Key('show-tile-tags')));
    await t.pumpAndSettle();
    expect(p.showTags, true);
    expect(changes, 1);
    expect(find.byKey(const Key('display-save-error')), findsOneWidget);
  });
  testWidgets('restores saved local choice', (t) async {
    final store = Store()..value = true;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DisplaySettings(preference: TileDisplayPreference(store)),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      t.widget<SwitchListTile>(find.byKey(const Key('show-tile-tags'))).value,
      true,
    );
  });
}
