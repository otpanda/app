import 'dart:convert';

import 'package:otpanda_client/browser_session_contract.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'product_shell_test.dart'
    show FakeTransport, AssignFake, routes, ok, pump, now;

class RuleFake extends FakeTransport implements RuleBridge {
  RuleFake(super.routes);
  int begins = 0;
  String ruleStatus = 'idle';
  Map? target;
  @override
  Future<String> readRules() async => '{}';
  @override
  Future<void> deleteRule(String id) async {}
  @override
  String get ruleState => ruleStatus;
  @override
  void ruleDismiss() {
    ruleStatus = 'idle';
  }

  @override
  Future<String> rulePrepare(String value) async {
    begins++;
    target = jsonDecode(value);
    ruleStatus = 'confirm';
    return jsonEncode({
      'operation': 'rule-from-review',
      'entryId': target!['entryId'],
      'label': 'Target',
      'accountName': '',
      'sender': 'example.test',
      'sourceId': 'src',
      'basis': 'template',
      'phrase': null,
      'futureRecipients': 0,
      'futureAutomations': 0,
      'otherAccountRules': 0,
      'irreversible': false,
      'proofRequired': false,
      'previewRemoved': true,
    });
  }

  @override
  Future<String> ruleConfirm() async => 'applied';
  @override
  Future<String> ruleReconcile() async => ruleStatus;
}

void main() {
  testWidgets(
    'fresh private code and retained detail share exactly one arrival card',
    (t) async {
      final tr = AssignFake({
        ...routes(),
        '/v1/manage/sources': ok({
          'sources': [
            {'source_id': 'src', 'kind': 'gmail', 'label': 'Personal'},
          ],
        }),
        '/v1/manage/unassigned': ok({
          'records': [
            {
              'sourceId': 'src',
              'eventId': 'event',
              'sourceLabel': 'Personal',
              'code': '123456',
              'receivedAt': now - 1,
              'expiresAt': now + 60000,
            },
          ],
        }),
        '/v1/manage/unassigned-context': ok({
          'contexts': [
            {
              'contextId': 'ctx',
              'sourceId': 'src',
              'eventId': 'event',
              'kind': 'email',
              'sender': 'example.test',
              'sourceLabel': 'Personal',
              'receivedAt': now - 1,
              'arrivedAt': now - 1,
              'retainedUntil': now + 100000,
              'redactedText': 'Code [redacted]',
              'contextUnavailable': false,
              'truncated': false,
            },
          ],
        }),
      });
      await pump(t, tr, assignmentEnabled: true);
      expect(find.text('New arrivals'), findsOneWidget);
      expect(find.text('123 456'), findsOneWidget);
      expect(find.byTooltip('Assign to an entry'), findsOneWidget);
      expect(find.byTooltip('Details'), findsOneWidget);
      expect(find.text('Needs assignment'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
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
      expect(find.byTooltip('Assign to an entry'), findsNothing);
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      await t.tap(find.byTooltip('Details'));
      await t.pumpAndSettle();
      expect(find.text('Unassigned details'), findsOneWidget);
      expect(find.text('Code [redacted]'), findsOneWidget);
      expect(find.text('Subject, code redacted'), findsOneWidget);
      expect(find.byTooltip('Assign to an entry'), findsNothing);
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('Back to codes'));
      await t.pumpAndSettle();
      expect(find.text('Unassigned details'), findsNothing);
    },
  );
  testWidgets(
    'expired redacted review can choose an owned entry and prepare only a future rule',
    (t) async {
      final tr = RuleFake({
        ...routes(
          entries: [
            {
              'entry_id': 'entry',
              'service_name': 'Target',
              'account_name': '',
              'capabilities': {'manage': true},
            },
          ],
        ),
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
      await t.tap(find.byTooltip('Details'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('save-review-rule')), findsOneWidget);
      expect(tr.begins, 0);
      await t.tap(find.byKey(const Key('save-review-rule')));
      await t.pumpAndSettle();
      await t.tap(find.text('Target').last);
      await t.pumpAndSettle();
      expect(tr.target, {
        'operation': 'review',
        'contextId': 'ctx',
        'entryId': 'entry',
      });
      expect(tr.begins, 1);
      expect(find.text('Confirm'), findsOneWidget);
    },
  );
}
