import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/assignment_dialog.dart';
import 'package:otpanda_client/browser_session_contract.dart';

class Bridge implements AssignmentBridge {
  int pendingFor = 0;
  bool private = false;
  Map<String, dynamic>? rule;
  int prompts = 0, checks = 0, prepares = 0;
  String outcome = 'assigned';
  @override
  String assignmentState = 'confirm';
  @override
  Future<String> assignmentPrepare(String target) async {
    prepares++;
    return jsonEncode({
      if (rule != null) 'rule': rule,
      'entryId': 'entry',
      'label': 'Northstar work',
      'accountName': 'work@example.test',
      'activeRecipients': private ? 0 : 2,
      'automationRecipients': private ? 0 : 1,
      'proofRequired': !private,
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
    if (pendingFor > 0) {
      pendingFor--;
      return 'pending';
    }
    return 'assigned';
  }

  @override
  void assignmentDismiss() {}
}

class DeviceBridge extends Bridge implements DeviceConfirmationBridge {}

void main() {
  testWidgets(
    'native proof copy names device, web proof copy remains passkey',
    (t) async {
      for (final device in [false, true]) {
        final b = device ? DeviceBridge() : Bridge();
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AssignmentDialog(
                key: ValueKey(device),
                bridge: b,
                sourceId: 'source',
                eventId: 'event',
                entryId: 'entry',
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.text(device ? 'Confirm with device' : 'Confirm with passkey'),
          findsOneWidget,
        );
        expect(
          find.text(device ? 'Confirm with passkey' : 'Confirm with device'),
          findsNothing,
        );
        expect(
          find.textContaining(
            device ? 'your device screen lock' : 'your passkey',
          ),
          findsOneWidget,
        );
      }
    },
  );
  testWidgets(
    'future template rule sharing is visible before deliberate confirmation',
    (t) async {
      final b = Bridge()
        ..rule = {
          'status': 'will_save',
          'sender': 'sender@example.test',
          'basis': 'template',
          'phrase': null,
          'futureRecipients': 2,
          'futureAutomations': 1,
        };
      await t.pumpWidget(
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
      await t.pumpAndSettle();
      expect(
        find.textContaining(
          'Future matching codes will be shared with 2 recipients / 1 automations.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Match: message template'), findsOneWidget);
      expect(
        find.textContaining('This does not assign future messages.'),
        findsNothing,
      );
      expect(b.prompts, 0);
      await t.tap(find.text('Confirm with passkey'));
      await t.pumpAndSettle();
      expect(b.prompts, 1);
    },
  );
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
      expect(find.text('Automation access grants: 1'), findsOneWidget);
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

  testWidgets('pending is rechecked by status with backoff, never re-begun', (
    tester,
  ) async {
    final b = Bridge()
      ..outcome = 'unknown'
      ..pendingFor = 2;
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
    await tester.tap(find.text('Check status'));
    await tester.pump();
    await tester.pump();
    expect(b.checks, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(b.checks, 2);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(b.checks, 3);
    expect(find.text('Assignment confirmed.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(b.checks, 3);
    expect(b.prepares, 1);
    expect(b.prompts, 1);
  });

  testWidgets('private entry: plain Confirm, no passkey wording', (
    tester,
  ) async {
    final b = Bridge()..private = true;
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
    expect(find.text('Confirm with passkey'), findsNothing);
    expect(find.textContaining('passkey'), findsNothing);
    expect(find.textContaining('Active recipients'), findsNothing);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(b.prompts, 1);
    expect(find.text('Assignment confirmed.'), findsOneWidget);
  });
}
