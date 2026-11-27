import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/organization_contract.dart';
import 'package:otpanda_client/read_workspace_controller.dart';

import 'product_shell_test.dart' show FakeTransport, routes, now;

void main() {
  for (final action in [
    'Cancel',
    'Apply',
    'Toggle then cancel',
    'Toggle then apply',
  ]) {
    testWidgets(
      'mixed batch tags $action changes only an explicit applied decision',
      (t) async {
        t.view.physicalSize = const Size(1280, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final c = ReadWorkspaceController(
          bridge: FakeTransport(
            routes(
              entries: [
                for (final id in ['a', 'b'])
                  {
                    'entry_id': id,
                    'service_name': id,
                    'capabilities': {'manage': true},
                  },
              ],
            ),
          ),
          clock: () => now,
        );
        addTearDown(c.dispose);
        await c.refresh();
        final org = OrganizationStore()
          ..reconcileEntries(['a', 'b'])
          ..createTag('work', 'Work')
          ..setTags('a', {'work'});
        var updates = 0;
        await t.pumpWidget(
          MaterialApp(
            theme: otpandaTheme(),
            home: ProductShell(
              controller: c,
              organization: org,
              onOrganizationChanged: () => updates++,
              onCopyAssigned: (_) async {},
              onCopyPrivate: (_) async {},
              clock: () => now,
              onSignedOut: () {},
            ),
          ),
        );
        await t.pumpAndSettle();
        final boxes = find.byType(Checkbox);
        expect(boxes, findsNWidgets(2));
        await t.tap(boxes.at(0));
        await t.pump();
        await t.tap(boxes.at(1));
        await t.pump();
        await t.tap(find.text('Tags'));
        await t.pumpAndSettle();
        final mixed = find.byType(CheckboxListTile);
        expect(t.widget<CheckboxListTile>(mixed).value, isNull);
        if (action.startsWith('Toggle')) {
          await t.tap(mixed);
          await t.pump();
          expect(t.widget<CheckboxListTile>(mixed).value, true);
        }
        final apply = action == 'Apply' || action == 'Toggle then apply';
        await t.tap(find.text(apply ? 'Apply' : 'Cancel'));
        await t.pumpAndSettle();
        expect(org.preferencesFor('a').tagIds, {'work'});
        expect(
          org.preferencesFor('b').tagIds,
          action == 'Toggle then apply' ? {'work'} : isEmpty,
        );
        expect(updates, apply ? 1 : 0);
        expect(t.takeException(), isNull);
      },
    );
  }
}
