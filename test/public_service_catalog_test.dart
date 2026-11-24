import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/public_service_catalog.dart';

void main() {
  testWidgets('bundled metadata has provenance and bounded literal search', (
    t,
  ) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final c = (await t.runAsync(() => PublicServiceCatalog.bundled()))!;
    expect(c.services.length, greaterThan(2000));
    expect(c.search('github').any((s) => s.host == 'github.com'), true);
    expect(c.search(''), isEmpty);
    expect(c.search('a').length, lessThanOrEqualTo(20));
    expect(c.search('.*'), isEmpty);
    expect(
      () => PublicServiceCatalog.parse(jsonEncode({'services': []})),
      throwsFormatException,
    );
  });
  test('parser rejects malformed metadata and unsafe rows', () {
    Map<String, dynamic> valid() => {
      'source': 'https://api.2fa.directory/v3/all.json',
      'attribution': 'Data sourced from 2FA Directory by 2factorauth.',
      'license': 'MIT',
      'signatureVerified': false,
      'sha256': '0' * 64,
      'fetchedAt': 1,
      'services': [
        {'id': 'example.test', 'name': 'Example', 'host': 'example.test'},
      ],
    };
    for (final change in <void Function(Map<String, dynamic>)>[
      (v) => v['fetchedAt'] = 8640000000000001,
      (v) => v['signatureVerified'] = true,
      (v) => v['attribution'] = 'changed',
      (v) => v['services'] = [
        {'id': '-bad.test', 'name': 'Bad', 'host': '-bad.test'},
      ],
      (v) => v['services'] = [
        {'id': '127.0.0.1', 'name': 'Bad', 'host': '127.0.0.1'},
      ],
      (v) => v['services'] = [
        {'id': 'x.internal', 'name': 'Bad', 'host': 'x.internal'},
      ],
      (v) => v['services'] = [
        {'id': 'ok.test', 'name': 'Bad\nName', 'host': 'ok.test'},
      ],
      (v) => v['services'] = [...v['services'], ...v['services']],
      (v) => v['services'] = [
        {
          'id': 'ok.test',
          'name': 'Bad',
          'host': 'ok.test',
          'sender': 'not allowed',
        },
      ],
    ]) {
      final data = valid();
      change(data);
      expect(
        () => PublicServiceCatalog.parse(jsonEncode(data)),
        throwsFormatException,
      );
    }
    expect(
      PublicServiceCatalog.parse(jsonEncode(valid())).services.single.id,
      'example.test',
    );
    expect(
      () => PublicServiceCatalog.parse('x' * (1024 * 1024 + 1)),
      throwsFormatException,
    );
  });
  testWidgets(
    'explicit selection fills label before local fictional creation',
    (t) async {
      await t.runAsync(() => PublicServiceCatalog.bundled());
      await t.pumpWidget(const OTPandaApp());
      await t.tap(find.text('Entries'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add entry'));
      await t.pumpAndSettle();
      await t.tap(find.text('Find a service'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, 'github');
      await t.pumpAndSettle();
      expect(find.text('github.com'), findsOneWidget);
      await t.tap(find.text('github.com'));
      await t.pumpAndSettle();
      expect(find.text('Create entry'), findsOneWidget);
      expect(find.textContaining('Fictional preview only'), findsOneWidget);
      await t.tap(find.text('Create entry'));
      await t.pumpAndSettle();
      expect(find.text('GitHub'), findsOneWidget);
      final dynamic state = t.state(find.byType(ClientHome));
      expect(state.entries.last.serviceId, 'github.com');
      expect(state.entries.last.websiteHost, 'github.com');
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'closing picker preserves custom entry and cancel creates nothing',
    (t) async {
      await t.runAsync(() => PublicServiceCatalog.bundled());
      await t.pumpWidget(const OTPandaApp());
      await t.tap(find.text('Entries'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add entry'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), 'Custom label');
      await t.tap(find.text('Find a service'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Close service picker'));
      await t.pumpAndSettle();
      expect(find.text('Custom label'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      final dynamic state = t.state(find.byType(ClientHome));
      expect(state.entries.length, 3);
      await t.tap(find.text('Add entry'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), 'Custom label');
      await t.tap(find.text('Create entry'));
      await t.pumpAndSettle();
      expect(state.entries.last.service, 'Custom label');
      expect(state.entries.last.serviceId, isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'label edits clear public identity on creation and existing entry',
    (t) async {
      await t.runAsync(() => PublicServiceCatalog.bundled());
      await t.pumpWidget(const OTPandaApp());
      await t.tap(find.text('Entries'));
      await t.pumpAndSettle();
      final dynamic state = t.state(find.byType(ClientHome));
      Future<void> pick() async {
        await t.tap(find.text('Add entry'));
        await t.pumpAndSettle();
        await t.tap(find.text('Find a service'));
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField).last, 'github');
        await t.pumpAndSettle();
        await t.tap(find.text('github.com'));
        await t.pumpAndSettle();
      }

      await pick();
      await t.enterText(find.byType(TextField).at(1), 'My Bank');
      await t.tap(find.text('Create entry'));
      await t.pumpAndSettle();
      expect(state.entries.last.serviceId, isNull);
      expect(state.entries.last.websiteHost, isNull);
      await pick();
      await t.tap(find.text('Create entry'));
      await t.pumpAndSettle();
      expect(state.entries.last.serviceId, 'github.com');
      await t.enterText(find.byType(TextField).first, 'GitHub');
      await t.pumpAndSettle();
      await t.tap(find.text('Edit entry'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(state.entries.last.serviceId, 'github.com');
      await t.tap(find.text('Edit entry'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(1), 'My Bank');
      await t.tap(find.text('Save changes'));
      await t.pumpAndSettle();
      expect(state.entries.last.serviceId, isNull);
      expect(state.entries.last.websiteHost, isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  test('name controls and UTF-16 bounds match refresh rules', () {
    Map<String, dynamic> value(String name) => {
      'source': 'https://api.2fa.directory/v3/all.json',
      'attribution': 'Data sourced from 2FA Directory by 2factorauth.',
      'license': 'MIT',
      'signatureVerified': false,
      'sha256': '0' * 64,
      'fetchedAt': 1,
      'services': [
        {'id': 'ok.test', 'name': name, 'host': 'ok.test'},
      ],
    };
    for (final code in [
      0x85,
      0x200b,
      0x200e,
      0x2028,
      0x2029,
      0x61c,
      0x110bd,
      0x1343f,
    ]) {
      expect(
        () => PublicServiceCatalog.parse(
          jsonEncode(value('x${String.fromCharCode(code)}y')),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => PublicServiceCatalog.parse(jsonEncode(value('😀' * 61))),
      throwsFormatException,
    );
    expect(
      PublicServiceCatalog.parse(jsonEncode(value('😀' * 60))).services.length,
      1,
    );
  });
  testWidgets('no-match fallback and close control fit popup size', (t) async {
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.view.physicalSize = const Size(390, 600);
    t.view.devicePixelRatio = 1;
    await t.runAsync(() => PublicServiceCatalog.bundled());
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: PublicServicePicker())),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'no-match-unusual-service');
    await t.pumpAndSettle();
    expect(find.textContaining('No matching service'), findsOneWidget);
    expect(find.byTooltip('Close service picker'), findsOneWidget);
    expect(t.takeException(), null);
    await t.pumpWidget(const SizedBox());
  });
}
