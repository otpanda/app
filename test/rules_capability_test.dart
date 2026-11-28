import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/rules_capability.dart';

import 'rules_capability_helpers.dart';

class Cap implements RuleBridge {
  Cap(this.answer);
  Future<String> Function() answer;
  int probes = 0;
  @override
  Future<String> rulesCapabilities() {
    probes++;
    return answer();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget host(RuleBridge b) => MaterialApp(
  home: RulesCapable(
    bridge: b,
    builder: (c, cap) => Text(
      cap == null
          ? 'NONE'
          : cap.available
          ? 'RULES'
          : cap.managementAvailable
          ? 'MGMT'
          : 'OFF',
    ),
  ),
);

void main() {
  test('only the exact explicit capability shape is believed', () {
    final all = parseRulesCapability(rulesAvailableJson)!;
    expect([all.available, all.managementAvailable, all.disconnectPolicy], [true, true, true]);
    final m = parseRulesCapability(rulesManagementOnlyJson)!;
    expect([m.available, m.managementAvailable, m.showsRules], [false, true, true]);
    final off = parseRulesCapability(rulesJson(available: false, management: false, policy: false))!;
    expect([off.available, off.managementAvailable, off.disconnectPolicy, off.showsRules], [false, false, false, false]);
    for (final bad in [
      '',
      'x',
      '[]',
      '{}',
      '{"version":1}',
      '{"version":1,"rules":{"available":true,"disconnectPolicy":true}}',
      '{"version":1,"rules":{"available":true,"managementAvailable":true}}',
      '{"version":1,"rules":{"available":"true","managementAvailable":true,"disconnectPolicy":true}}',
      '{"version":1,"rules":{"available":true,"managementAvailable":1,"disconnectPolicy":true}}',
      '{"version":1,"rules":{"available":true,"managementAvailable":true,"disconnectPolicy":null}}',
      '{"version":1,"rules":{"available":true,"managementAvailable":true,"disconnectPolicy":true,"x":1}}',
      '{"version":2,"rules":{"available":true,"managementAvailable":true,"disconnectPolicy":true}}',
      '{"version":1,"rules":{"available":true,"managementAvailable":true,"disconnectPolicy":true},"y":1}',
    ]) {
      expect(parseRulesCapability(bad), isNull, reason: bad);
    }
  });
  testWidgets('shown only per exact answer; unknown and failed hide, management-only is distinct', (t) async {
    for (final (answer, shown) in <(Future<String> Function(), String)>[
      (() async => rulesAvailableJson, 'RULES'),
      (() async => rulesManagementOnlyJson, 'MGMT'),
      (() async => rulesJson(available: false, management: false), 'OFF'),
      (() async => '{}', 'NONE'),
      (() async => throw StateError('404'), 'NONE'),
    ]) {
      await t.pumpWidget(host(Cap(answer)));
      await t.pumpAndSettle();
      expect(find.text(shown), findsOneWidget);
    }
  });
  testWidgets('hidden while the probe is pending', (t) async {
    final c = Completer<String>();
    await t.pumpWidget(host(Cap(() => c.future)));
    expect(find.text('NONE'), findsOneWidget);
    c.complete(rulesAvailableJson);
    await t.pumpAndSettle();
    expect(find.text('RULES'), findsOneWidget);
  });
  testWidgets('a late available answer for a replaced bridge cannot show rules, and a failed new probe clears the old available', (t) async {
    final slow = Completer<String>();
    final first = Cap(() => slow.future);
    await t.pumpWidget(host(first));
    final second = Cap(() async => throw StateError('config failed'));
    await t.pumpWidget(host(second));
    slow.complete(rulesAvailableJson);
    await t.pumpAndSettle();
    expect(find.text('NONE'), findsOneWidget);
    // available, then the bridge changes (new session) and its probe fails.
    await t.pumpWidget(host(Cap(() async => rulesAvailableJson)));
    await t.pumpAndSettle();
    expect(find.text('RULES'), findsOneWidget);
    await t.pumpWidget(host(Cap(() async => throw StateError('x'))));
    await t.pumpAndSettle();
    expect(find.text('NONE'), findsOneWidget);
  });
  testWidgets('answer after dispose is dropped without error', (t) async {
    final c = Completer<String>();
    await t.pumpWidget(host(Cap(() => c.future)));
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    c.complete(rulesAvailableJson);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
