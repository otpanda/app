import 'dart:io';
import 'package:flutter/services.dart';

import 'dart:convert';

import 'rules_capability_helpers.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/entry_rule_sources.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/rule_action_dialog.dart';

class Rules implements RuleBridge {
  String state = 'idle';
  int sends = 0, begins = 0, deletes = 0;
  String result = 'applied';
  @override
  Future<String> rulesCapabilities() async => capability;
  String capability = rulesAvailableJson;
  @override
  Future<String> readRules() async => jsonEncode({
    'rules': [
      {
        'ruleId': 'r1',
        'entryId': 'entry',
        'sourceId': 'source',
        'sourceLabel': 'Personal Gmail',
        'kind': 'gmail',
        'sender': 'noreply@bank.example',
        'basis': 'template',
        'phrase': null,
        'status': 'active',
      },
      {
        'ruleId': 'r2',
        'entryId': 'entry',
        'sourceId': 'source',
        'sourceLabel': 'Personal Gmail',
        'kind': 'gmail',
        'sender': 'notify@shop.example',
        'basis': 'phrase',
        'phrase': 'shop',
        'status': 'paused',
      },
    ],
  });
  @override
  Future<void> deleteRule(String id) async {
    deletes++;
  }

  @override
  Future<String> rulePrepare(String target) async {
    begins++;
    state = 'confirm';
    final t = jsonDecode(target);
    return jsonEncode({
      'operation': t['operation'] == 'resume' ? 'rule-resume' : 'rule-edit',
      'entryId': 'entry',
      'label': 'Personal bank',
      'accountName': 'person@example.test',
      'sender': 'notify@shop.example',
      'senderKind': 'email_address',
      'sourceId': 'source',
      'serviceId': 'bank',
      'basis': 'phrase',
      'phrase': 'shop',
      'futureRecipients': 2,
      'futureAutomations': 1,
      'otherAccountRules': 1,
      'resumesPausedRule': true,
      'irreversible': false,
      'proofRequired': true,
    });
  }

  @override
  Future<String> ruleConfirm() async {
    sends++;
    state = result;
    return state;
  }

  @override
  Future<String> ruleReconcile() async => state;
  @override
  String get ruleState => state;
  @override
  void ruleDismiss() {
    state = 'idle';
  }
}

void main() {
  setUpAll(() async {
    for (final family in ['Roboto', 'Figtree']) {
      final loader = FontLoader(family)
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/Figtree-400.ttf').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
    }
  });
  testWidgets(
    'persistent source controls distinguish paused, no mutation until review and confirmation',
    (t) async {
      final b = Rules();
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Figtree'),
          home: Scaffold(
            body: EntryRuleSources(bridge: b, entryId: 'entry'),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Change match'), findsOneWidget);
      expect(b.sends, 0);
      await t.tap(find.text('Resume'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('2 recipients and 1 automation grant'),
        findsOneWidget,
      );
      expect(b.sends, 0);
      await t.tap(find.text('Confirm with passkey'));
      await t.pumpAndSettle();
      expect(b.sends, 1);
      expect(
        find.text('Rule confirmed for future matching codes.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'unknown reopen never begins a replacement and paused result never says confirmed',
    (t) async {
      final b = Rules()..state = 'unknown';
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Figtree'),
          home: Scaffold(
            body: RuleActionDialog(
              bridge: b,
              target: const {
                'operation': 'resume',
                'entryId': 'entry',
                'ruleId': 'r2',
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(b.begins, 0);
      expect(find.text('Check status'), findsOneWidget);
      expect(find.text('Confirm with passkey'), findsNothing);
    },
  );
  testWidgets('rules source and confirmation visual evidence390and1280', (
    t,
  ) async {
    final b = Rules();
    for (final width in [390.0, 1280.0]) {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Figtree'),
            home: Scaffold(
              appBar: AppBar(title: const Text('Account Sources')),
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: EntryRuleSources(bridge: b, entryId: 'entry'),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('Resume'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
    }
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}
