import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'product_shell_test.dart' show FakeTransport, routes, ok, pump, now;

void main() {
  testWidgets(
    'expired retained context opens redacted details but no assign or copy',
    (t) async {
      final tr = FakeTransport({
        ...routes(),
        '/v1/manage/unassigned-context': ok({
          'contexts': [
            {
              'contextId': 'ctx',
              'sourceId': 'src',
              'eventId': 'event',
              'kind': 'email',
              'sender': 'example.test',
              'sourceLabel': 'Personal',
              'receivedAt': now - 600000,
              'arrivedAt': now - 600000,
              'retainedUntil': now + 100000,
              'redactedText': 'Code [redacted]',
              'contextUnavailable': false,
              'truncated': false,
            },
          ],
        }),
      });
      await pump(t, tr, assignmentEnabled: true);
      expect(find.text('Needs assignment'), findsOneWidget);
      expect(find.byTooltip('Assign'), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      await t.tap(find.byTooltip('Details'));
      await t.pumpAndSettle();
      expect(find.text('Unassigned details'), findsOneWidget);
      expect(find.text('Code [redacted]'), findsOneWidget);
      expect(find.text('Subject, code redacted'), findsOneWidget);
      expect(find.byTooltip('Assign'), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.text('Unassigned details'), findsNothing);
    },
  );
}
