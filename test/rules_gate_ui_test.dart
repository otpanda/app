import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/account_details_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/organization_contract.dart';
import 'package:otpanda_client/session_contract.dart';

import 'product_shell_test.dart' show ManagedFake, routes;
import 'rules_capability_helpers.dart';

class GateFake extends ManagedFake implements RuleBridge {
  GateFake() : super(routes());
  String capability = rulesAvailableJson;
  bool empty = false;
  int reads = 0, deletes = 0;
  @override
  Future<String> rulesCapabilities() async => capability;
  @override
  Future<String> readRules() async {
    reads++;
    return jsonEncode({
      'rules': [
        for (final s in empty ? <String>[] : ['active', 'paused'])
          {
            'ruleId': 'r-$s',
            'entryId': 'a',
            'sourceId': 'src',
            'sourceLabel': 'Personal Gmail',
            'kind': 'gmail',
            'sender': '$s@bank.example',
            'basis': 'sender',
            'phrase': null,
            'status': s,
          },
      ],
    });
  }

  @override
  Future<void> deleteRule(String id) async => deletes++;
  @override
  Future<String> rulePrepare(String target) async => throw StateError('no');
  @override
  Future<String> ruleConfirm() async => throw StateError('no');
  @override
  Future<String> ruleReconcile() async => 'idle';
  @override
  String get ruleState => 'idle';
  @override
  void ruleDismiss() {}
}

Future<void> details(
  WidgetTester t,
  GateFake b, {
  bool totp = false,
  ThemeData? theme,
}) async {
  final org = OrganizationStore()..reconcileEntries(['a']);
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      home: AccountDetailsPage(
        entry: ManagedEntry('a', 'Bank', 'login', true, totp),
        bridge: b,
        organization: org,
        isCurrent: () => true,
        onClose: () {},
        onConfirmed: ({service, account}) {},
        onOrganizationSaved: () async => true,
        editTags: (draft) async {},
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('available: full controls on a non-TOTP entry', (t) async {
    final b = GateFake();
    await details(t, b);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Change match'), findsOneWidget);
    expect(
      t.getTopLeft(find.text('Sources')).dx,
      t.getTopLeft(find.text('Title')).dx,
    );
    expect(
      t.getTopLeft(find.text('Sources')).dx,
      t.getTopLeft(find.text('Tags')).dx,
    );
    expect(
      t.getTopLeft(find.text('Sources')).dx,
      t.getTopLeft(find.text('Login')).dx,
    );
    expect(find.text('Delete rule'), findsNWidgets(2));
  });
  testWidgets('management only: existing rules deletable, nothing creatable', (
    t,
  ) async {
    final b = GateFake()..capability = rulesManagementOnlyJson;
    await details(t, b);
    expect(find.text('Delete rule'), findsNWidgets(2));
    expect(find.text('Resume'), findsNothing);
    expect(find.text('Change match'), findsNothing);
  });
  testWidgets(
    'neither available nor management, or unknown: no rules, no read',
    (t) async {
      for (final c in [
        rulesJson(available: false, management: false),
        '{}',
        '{"version":1,"rules":{"available":true,"managementAvailable":true}}',
      ]) {
        final b = GateFake()..capability = c;
        await details(t, b);
        expect(find.text('Delete rule'), findsNothing, reason: c);
        expect(b.reads, 0, reason: c);
      }
    },
  );
  for (final totp in [false, true]) {
    testWidgets('management-only, zero rules, totp=$totp: no dead rule text', (
      t,
    ) async {
      final b = GateFake()
        ..capability = rulesManagementOnlyJson
        ..empty = true;
      await details(t, b, totp: totp);
      expect(b.reads, 1);
      expect(find.textContaining('No saved'), findsNothing);
      expect(find.textContaining('Loading matching'), findsNothing);
      expect(find.text('Delete rule'), findsNothing);
      expect(find.text('Sources'), totp ? findsOneWidget : findsNothing);
      expect(
        find.text('Authenticator codes'),
        totp ? findsOneWidget : findsNothing,
      );
    });
    testWidgets('available, zero rules, totp=$totp: meaningful empty text', (
      t,
    ) async {
      final b = GateFake()..empty = true;
      await details(t, b, totp: totp);
      expect(find.text('No saved email or SMS rules.'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
    });
  }
}
