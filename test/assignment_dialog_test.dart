import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/assignment_dialog.dart';
import 'package:otpanda_client/browser_session_contract.dart';

class Bridge implements AssignmentBridge {
  int prompts = 0, checks = 0, prepares = 0;
  String outcome = 'assigned';
  @override
  String assignmentState = 'confirm';
  @override
  Future<String> assignmentPrepare(String target) async {
    prepares++;
    return jsonEncode({
      'entryId': 'entry',
      'label': 'Northstar work',
      'accountName': 'work@example.test',
      'activeRecipients': 2,
      'automationRecipients': 1,
      'irreversible': true,
    });
  }

  @override
  Future<String> assignmentConfirm() async {
    prompts++;
    return outcome;
  }

  @override
  Future<String> assignmentReconcile() async {
    checks++;
    return 'assigned';
  }

  @override
  void assignmentDismiss() {}
}

void main() {
  testWidgets(
    'definitive negative receipt is distinct from unknown and has no resubmit',
    (tester) async {
      final b = Bridge()..outcome = 'not-assigned';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssignmentDialog(
              bridge: b,
              sourceId: 'source',
              eventId: 'event',
              entryId: 'entry',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm with passkey'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Server confirmed this assignment did not happen'),
        findsOneWidget,
      );
      expect(find.text('Confirm with passkey'), findsNothing);
      expect(find.text('Check status'), findsNothing);
      expect(find.text('Close'), findsOneWidget);
      expect(b.prompts, 1);
    },
  );

  testWidgets(
    'reopening unresolved outcome never prepares or confirms a replacement',
    (tester) async {
      final b = Bridge()..assignmentState = 'unknown';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssignmentDialog(
              bridge: b,
              sourceId: 'source',
              eventId: 'other',
              entryId: 'other',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(b.prepares, 0);
      expect(b.prompts, 0);
      expect(find.textContaining('It may have happened'), findsOneWidget);
      expect(find.text('Confirm with passkey'), findsNothing);
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(b.checks, 1);
      expect(b.prepares, 0);
    },
  );

  testWidgets(
    'server summary and irreversible exposure precede deliberate gesture',
    (tester) async {
      final b = Bridge();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AssignmentDialog(
              bridge: b,
              sourceId: 'source',
              eventId: 'event',
              entryId: 'entry',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Northstar work'), findsOneWidget);
      expect(find.text('Active recipients: 2'), findsOneWidget);
      expect(find.text('Recipients with automation access: 1'), findsOneWidget);
      expect(find.textContaining('cannot undo'), findsOneWidget);
      expect(b.prompts, 0);
      await tester.tap(find.text('Confirm with passkey'));
      await tester.pumpAndSettle();
      expect(b.prompts, 1);
      expect(find.text('Assignment confirmed.'), findsOneWidget);
    },
  );
  testWidgets('unknown is not failure, bounded status exposed separately', (
    tester,
  ) async {
    final b = Bridge()..outcome = 'unknown';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssignmentDialog(
            bridge: b,
            sourceId: 'source',
            eventId: 'event',
            entryId: 'entry',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm with passkey'));
    await tester.pumpAndSettle();
    expect(find.textContaining('It may have happened'), findsOneWidget);
    expect(find.text('Confirm with passkey'), findsNothing);
    await tester.tap(find.text('Check status'));
    await tester.pumpAndSettle();
    expect(b.checks, 1);
    expect(b.prompts, 1);
    expect(find.text('Assignment confirmed.'), findsOneWidget);
  });
}
