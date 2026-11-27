import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/public_service_catalog.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/service_directory.dart';
import 'package:otpanda_client/session_contract.dart';

import 'product_shell_test.dart' show FakeTransport, now, ok, routes;

/// The real ProductShell "Add authenticator" flow with a fake bridge that
/// records what the dialog hands to the enrollment call.
class _Bridge extends FakeTransport implements TotpManagementBridge {
  final adds = <List<String?>>[];
  _Bridge(super.routes);
  @override
  Future<String> addTotp(
    String label,
    String account,
    String secret, {
    String? catalogId,
  }) async {
    adds.add([label, account, catalogId]);
    return 'new-entry';
  }

  @override
  Future<SessionResponse> totpCode(String entryId) async =>
      const SessionResponse(404, '{}');
}

Future<_Bridge> _open(WidgetTester t) async {
  await t.runAsync(() => PublicServiceCatalog.bundled());
  ServiceDirectory.instance = ServiceDirectory(
    useDefaultStore: false,
    client: () =>
        MockClient((_) async => throw http.ClientException('offline')),
  );
  await t.runAsync(ServiceDirectory.instance.ensureLoaded);
  final bridge = _Bridge({
    ...routes(),
    '/v1/manage/account': ok({'passkeys': 1}),
  });
  t.view.physicalSize = const Size(420, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final c = ReadWorkspaceController(bridge: bridge, clock: () => now);
  addTearDown(c.dispose);
  await c.refresh();
  await t.pumpWidget(
    MaterialApp(
      home: ProductShell(
        controller: c,
        onCopyAssigned: (_) async {},
        onCopyPrivate: (_) async {},
        clock: () => now,
        onSignedOut: () {},
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.text('Add authenticator'));
  // The camera view animates forever on the host: pump a bounded time.
  await t.pump();
  await t.pump(const Duration(milliseconds: 500));
  if (find.text('Enter key manually').evaluate().isNotEmpty) {
    await t.tap(find.text('Enter key manually'));
    await t.pumpAndSettle();
  }
  await t.enterText(
    find.widgetWithText(TextField, 'Setup key'),
    'JBSWY3DPEHPK3PXP',
  );
  await t.pumpAndSettle();
  await t.tap(find.text('Next'));
  await t.pumpAndSettle();
  return bridge;
}

Future<void> pick(WidgetTester t) async {
  await t.tap(find.byKey(const Key('find-service')));
  await t.pumpAndSettle();
  await t.enterText(find.byType(TextField).last, 'github');
  await t.pumpAndSettle();
  await t.tap(find.text('github.com'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('real shell dialog: picked service sends catalogId and name', (
    t,
  ) async {
    final b = await _open(t);
    await pick(t);
    expect(find.byKey(const Key('chosen-service')), findsOneWidget);
    expect(find.widgetWithText(TextField, 'GitHub'), findsOneWidget);
    await t.tap(find.text('Verify and add'));
    await t.pumpAndSettle();
    expect(b.adds.single, ['GitHub', '', 'github.com']);
  });

  testWidgets('editing the name keeps the chosen service; remove drops it', (
    t,
  ) async {
    final b = await _open(t);
    await pick(t);
    await t.enterText(find.widgetWithText(TextField, 'GitHub'), 'Work GitHub');
    await t.pumpAndSettle();
    expect(find.byKey(const Key('chosen-service')), findsOneWidget);
    await t.tap(find.byKey(const Key('remove-service')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('find-service')), findsOneWidget);
    await t.tap(find.text('Verify and add'));
    await t.pumpAndSettle();
    expect(b.adds.single, ['Work GitHub', '', null]);
  });

  testWidgets('no pick sends no catalogue identity', (t) async {
    final b = await _open(t);
    await t.enterText(find.widgetWithText(TextField, 'Display name'), 'Mine');
    await t.tap(find.text('Verify and add'));
    await t.pumpAndSettle();
    expect(b.adds.single, ['Mine', '', null]);
  });

  test('read entries: catalogId wins, legacy service_id falls back, rename keeps logo', () async {
    ManagedEntry e(Map<String, Object?> extra) => ManagedEntry.fromJson({
      'entry_id': 'e',
      'service_name': 'Renamed label',
      'capabilities': {'manage': true},
      'service_id': 'custom-totp',
      ...extra,
    });
    expect(e({'catalogId': 'github.com'}).catalogId, 'github.com');
    expect(e({}).catalogId, isNull);
    expect(e({'catalogId': 'Bad Value'}).catalogId, isNull);
    expect(
      e({'catalogId': null, 'service_id': 'gitlab.com'}).catalogId,
      'gitlab.com',
    );
    expect(
      e({'catalogId': 'github.com', 'service_id': 'gitlab.com'}).catalogId,
      'github.com',
    );
    final d = ServiceDirectory(
      useDefaultStore: false,
      client: () => MockClient((_) async => throw http.ClientException('x')),
    );
    await d.ensureLoaded();
    final hit = d.resolve(
      serviceId: e({'catalogId': 'github.com'}).catalogId,
      name: 'Renamed label',
    );
    expect(hit?.icon, 'github.com.svg');
  });

  testWidgets('every picker row id is a valid lowercase catalogId', (t) async {
    await t.runAsync(() => PublicServiceCatalog.bundled());
    final d = ServiceDirectory(
      useDefaultStore: false,
      client: () => MockClient((_) async => throw http.ClientException('x')),
    );
    await t.runAsync(d.ensureLoaded);
    final rows = PublicServiceCatalog.fromDirectory(d.services, 0).services;
    final ok = RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$');
    expect(rows.length, greaterThan(1000));
    final bad = rows.where(
      (r) => !ok.hasMatch(r.id) || r.id != r.id.toLowerCase(),
    );
    expect(bad, isEmpty);
    // The id is the catalogue primary domain, never the display name.
    final gh = rows.firstWhere((r) => r.name == 'GitHub');
    expect(gh.id, 'github.com');
  });

  test(
    'catalogId consumers preserve cosmetic identity without authorization',
    () {
      // The id is owner-asserted and untrusted. It may feed display and the
      // exact fetched-catalogue lookup, never a service key, sender rule,
      // assignment or grouping. Any new consumer fails here and needs review.
      final users = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final n = f.path.replaceAll('\\', '/').split('/').last;
        if (RegExp(r'\.catalogId\b').hasMatch(f.readAsStringSync()))
          users.add(n);
      }
      users.sort();
      // Native cache and transfer preserve/authenticate the exact cosmetic id.
      // Export only reports omission for external formats, never uses catalogId
      // to select a seed, group, service key or sharing permission.
      expect(users, [
        'export_encoders.dart',
        'export_entry.dart',
        'export_seal.dart',
        'native_workspace_snapshot.dart',
        'product_shell.dart',
        'sealed_export_source.dart',
        'session_contract.dart',
        'transfer_pages.dart',
      ]);
      final export = File('lib/transfer/export_encoders.dart')
          .readAsStringSync();
      expect(export, contains('ExportNotCarried.catalogId'));
      final source = File('lib/transfer/sealed_export_source.dart')
          .readAsStringSync();
      expect(source, contains('catalog != a.catalogId'));
      final seal = File('lib/transfer/export_seal.dart').readAsStringSync();
      expect(seal, contains('f.catalogId'));
    },
  );
}
