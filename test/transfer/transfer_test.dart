import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/offline_totp/google_migration.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/offline_totp/otpauth_uri.dart';
import 'package:otpanda_client/offline_totp/import_outcome.dart';
import 'package:otpanda_client/transfer/import_formats.dart';
import 'package:otpanda_client/transfer/migration_collection.dart';
import 'package:otpanda_client/transfer/export_plan.dart';
import 'package:otpanda_client/transfer/import_review.dart';
import 'package:otpanda_client/transfer/qr_import_detector.dart';
import 'package:otpanda_client/transfer/transfer_pages.dart';
import 'package:otpanda_client/transfer/universal_scanner.dart';

OtpAccount acct(
  String name, {
  String? issuer = 'Example',
  int fill = 1,
  int period = 30,
  int digits = 6,
  int len = 20,
}) => OtpAccount(
  issuer: issuer,
  accountName: name,
  secret: Uint8List.fromList(List.filled(len, fill)),
  period: period,
  digits: digits,
);

class FakeSaver implements ImportSaver {
  FakeSaver({this.atomic = true, this.outcome = ImportSaveOutcome.saved});
  @override
  final bool atomic;
  ImportSaveOutcome outcome;
  final saved = <List<OtpAccount>>[];
  @override
  Future<ImportSaveOutcome> save(List<OtpAccount> a) async {
    saved.add(a);
    return outcome;
  }
}

class FakeSource implements SeedExportSource {
  FakeSource(this.accounts, {this.fail});
  final List<OtpAccount> accounts;
  final ExportAuthOutcome? fail;
  int calls = 0;
  @override
  ({bool available, String? reason}) get availability =>
      (available: true, reason: null);
  @override
  Future<List<OtpAccount>> exportAll() async {
    calls++;
    if (fail != null) throw ExportAuthException(fail!);
    return accounts;
  }
}

class PendingSource implements SeedExportSource {
  final result = Completer<List<OtpAccount>>();
  @override
  ({bool available, String? reason}) get availability =>
      (available: true, reason: null);
  @override
  Future<List<OtpAccount>> exportAll() => result.future;
}

Widget app(Widget child) =>
    MaterialApp(theme: buildOtpandaTheme(Brightness.light), home: child);

void main() {
  test('detector routes by scheme only', () {
    expect(
      detectImportQr('otpauth://totp/a?secret=AAAA'),
      ImportQrKind.otpauthSingle,
    );
    expect(detectImportQr(' OTPAUTH://hotp/a '), ImportQrKind.otpauthSingle);
    expect(
      detectImportQr('otpauth-migration://offline?data=x'),
      ImportQrKind.googleMigration,
    );
    expect(detectImportQr('https://example.com'), ImportQrKind.unknown);
    expect(detectImportQr(''), ImportQrKind.unknown);
  });

  test('review model skips duplicates by default, toggles, never stringifies secrets', () {
    final m = ImportReviewModel(
      [acct('one'), acct('two'), acct('two', fill: 2)],
      existing: {('Example', 'one')},
    );
    expect(m.include, [false, true, false]);
    expect(m.duplicateCount, 2);
    expect(m.selected().map((a) => a.accountName), ['two']);
    m.toggle(0);
    expect(m.selectedCount, 2);
    expect(m.toString(), 'ImportReviewModel(redacted)');
  });

  test('Google export keeps every account, changes only what Google cannot hold, and says so', () {
    final plan = planGoogleExport([
      acct('a'),
      acct('b', period: 60),
      acct('c', digits: 8),
      acct('d', digits: 7),
    ]);
    expect(plan.accounts.length, 4);
    expect(plan.accounts.map((a) => a.period).toSet(), {30, 60});
    expect(plan.accounts[2].digits, 8);
    expect(plan.accounts[3].digits, 7);
    expect(plan.notes.map((n) => (n.accountName, n.change, n.from)), [
      ('b', GoogleExportChange.periodDropped, 60),
      ('d', GoogleExportChange.digitsAdjusted, 7),
    ]);
    final orig = acct('b', period: 60);
    planGoogleExport([orig]);
    expect(orig.period, 60);
    expect(googleExportUris(plan.accounts, batchId: 3), isNotNull);
  });

  test('file formats round-trip through the preserved adapters and are detected by content', () {
    final accounts = [
      acct('a@example.com', issuer: 'GitHub'),
      acct('b@example.com', issuer: 'Google', fill: 2, period: 60),
    ];
    var n = 0;
    String uuid() =>
        '00000000-0000-4000-8000-${(n++).toString().padLeft(12, '0')}';
    for (final (f, kind) in [
      (ExportFileFormat.otpauthList, ImportFileFormat.otpauthList),
      (ExportFileFormat.aegisPlain, ImportFileFormat.aegisPlain),
      (ExportFileFormat.bitwardenJson, ImportFileFormat.bitwardenJson),
      (ExportFileFormat.bitwardenCsv, ImportFileFormat.bitwardenCsv),
    ]) {
      final text = exportFileText(f, accounts, newUuid: uuid);
      expect(detectImportFile(text), kind, reason: f.name);
      final o = parseImportFile(text);
      expect(o.skipped, isEmpty, reason: f.name);
      expect(o.accounts.map((a) => (a.issuer, a.accountName, a.period)), [
        ('GitHub', 'a@example.com', 30),
        ('Google', 'b@example.com', 60),
      ], reason: f.name);
    }
    expect(detectImportFile('hello'), isNull);
    expect(() => parseImportFile('hello'), throwsA(isA<OtpFormatException>()));
  });

  test('import review keeps assumed parameters from a Google export', () {
    final uris = encodeMigrationUris([
      acct('one'),
      acct('two', fill: 2),
    ], batchId: 9);
    final c = MigrationCollection()..scan(uris.single);
    final model = ImportReviewModel.fromOutcome(c.outcome());
    expect(model.items.length, 2);
    expect(
      model.items.every((i) => i.assumed.contains(OtpAssumption.period)),
      isTrue,
    );
    expect(model.skipped, isEmpty);
  });

  test(
    'export QR parts fit the QR size cap and round-trip through the decoder',
    () {
      final accounts = [
        for (var i = 0; i < 25; i++)
          acct('user$i@example.com', fill: i + 1, len: 64),
      ];
      final uris = googleExportUris(accounts, batchId: 7)!;
      expect(uris.every((u) => u.length <= maxExportQrChars), isTrue);
      final back = assembleBatches([
        for (final u in uris.reversed) parseMigrationUri(u),
      ]);
      expect(
        back.map((a) => a.accountName).toList()..sort(),
        accounts.map((a) => a.accountName).toList()..sort(),
      );
      expect(googleExportUris(const [], batchId: 1), isNull);
    },
  );

  testWidgets('scanner: single setup QR returns ScannedSingle', (t) async {
    void Function(String)? feed;
    ScanOutcome? got;
    await t.pumpWidget(
      app(
        Builder(
          builder: (c) => TextButton(
            onPressed: () async =>
                got = await Navigator.of(c).push<ScanOutcome>(
                  MaterialPageRoute(
                    builder: (_) => UniversalScannerPage(
                      camera: (on, err) {
                        feed = on;
                        return const SizedBox();
                      },
                    ),
                  ),
                ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    feed!('https://nope.example');
    await t.pump();
    expect(
      find.textContaining('not an authenticator setup or export'),
      findsOneWidget,
    );
    feed!(encodeOtpauthUri(acct('me')));
    await t.pumpAndSettle();
    expect(got, isA<ScannedSingle>());
  });

  testWidgets(
    'scanner: multi-part Google export waits for every part, any order, repeats ignored',
    (t) async {
      void Function(String)? feed;
      ScanOutcome? got;
      final qr = encodeMigrationUris(
        [acct('one'), acct('two'), acct('three')],
        batchId: 5,
        perBatch: 1,
      );
      final other = encodeMigrationUris([acct('x', fill: 9)], batchId: 6);
      await t.pumpWidget(
        app(
          Builder(
            builder: (c) => TextButton(
              onPressed: () async =>
                  got = await Navigator.of(c).push<ScanOutcome>(
                    MaterialPageRoute(
                      builder: (_) => UniversalScannerPage(
                        camera: (on, err) {
                          feed = on;
                          return const SizedBox();
                        },
                      ),
                    ),
                  ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      feed!(qr[2]);
      await t.pump();
      feed!(qr[2]);
      await t.pump();
      expect(find.textContaining('scanned 1 of 3'), findsOneWidget);
      feed!(other.single);
      await t.pump();
      expect(find.textContaining('different export'), findsOneWidget);
      expect(got, isNull);
      feed!(qr[0]);
      await t.pump();
      expect(find.textContaining('scanned 2 of 3'), findsOneWidget);
      feed!(qr[1]);
      await t.pumpAndSettle();
      expect(got, isA<ScannedMigration>());
      expect(
        (got as ScannedMigration).outcome.accounts.map((a) => a.accountName),
        ['one', 'two', 'three'],
      );
    },
  );

  testWidgets('scanner: back out returns null, nothing handed over', (t) async {
    ScanOutcome? got = ScannedMigration(const ImportOutcome([], []));
    await t.pumpWidget(
      app(
        Builder(
          builder: (c) => TextButton(
            onPressed: () async => got = await Navigator.of(c)
                .push<ScanOutcome>(
                  MaterialPageRoute(
                    builder: (_) => UniversalScannerPage(
                      camera: (on, err) => const SizedBox(),
                    ),
                  ),
                ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.pageBack();
    await t.pumpAndSettle();
    expect(got, isNull);
  });

  testWidgets('review: confirm saves only selected; cancel saves nothing', (
    t,
  ) async {
    final saver = FakeSaver();
    final m = ImportReviewModel(
      [acct('one'), acct('two')],
      existing: {('Example', 'one')},
    );
    bool? result;
    await t.pumpWidget(
      app(
        Builder(
          builder: (c) => TextButton(
            onPressed: () async => result = await Navigator.of(c).push<bool>(
              MaterialPageRoute(
                builder: (_) => ImportReviewPage(model: m, saver: saver),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Import 1 account'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(result, false);
    expect(saver.saved, isEmpty);
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Import 1 account'));
    await t.pumpAndSettle();
    expect(result, true);
    expect(saver.saved.single.map((a) => a.accountName), ['two']);
  });

  testWidgets(
    'review: several accounts with a non-atomic saver cannot be saved',
    (t) async {
      final saver = FakeSaver(atomic: false);
      await t.pumpWidget(
        app(
          ImportReviewPage(
            model: ImportReviewModel([acct('one'), acct('two')]),
            saver: saver,
          ),
        ),
      );
      expect(find.textContaining('not available yet'), findsOneWidget);
      final b = t.widget<FilledButton>(find.byType(FilledButton));
      expect(b.onPressed, isNull);
      expect(saver.saved, isEmpty);
    },
  );

  for (final (o, text) in [
    (ImportSaveOutcome.notSaved, 'Nothing was saved'),
    (ImportSaveOutcome.unknown, 'could not confirm'),
    (ImportSaveOutcome.cancelled, 'Cancelled'),
  ]) {
    testWidgets('review: $o is explained and stays on the page', (t) async {
      await t.pumpWidget(
        app(
          ImportReviewPage(
            model: ImportReviewModel([acct('one')]),
            saver: FakeSaver(outcome: o),
          ),
        ),
      );
      await t.tap(find.text('Import 1 account'));
      await t.pumpAndSettle();
      expect(find.textContaining(text), findsOneWidget);
      expect(find.byType(ImportReviewPage), findsOneWidget);
    });
  }

  testWidgets(
    'export: reauth cancel shows nothing; success shows QR and refused list; lifecycle hides',
    (t) async {
      final cancel = FakeSource([acct('a')], fail: ExportAuthOutcome.cancelled);
      await t.pumpWidget(app(ExportCodesPage(source: cancel)));
      await t.tap(find.text('Confirm with passkey'));
      await t.pumpAndSettle();
      expect(find.textContaining('Nothing was shown'), findsOneWidget);
      expect(find.text('QR code'), findsNothing);

      final src = FakeSource([acct('a'), acct('slow', period: 60)]);
      await t.pumpWidget(app(ExportCodesPage(source: src)));
      await t.tap(find.text('Confirm with passkey'));
      await t.pumpAndSettle();
      expect(find.textContaining('QR code 1 of 1'), findsOneWidget);
      expect(find.textContaining('slow'), findsOneWidget);
      expect(find.textContaining('will use 30 s'), findsOneWidget);
      expect(find.textContaining('exported anyway'), findsOneWidget);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        t.binding.handleAppLifecycleStateChanged(s);
      }
      await t.pump();
      expect(find.textContaining('QR code 1 of 1'), findsNothing);
      expect(find.textContaining('Hidden'), findsOneWidget);
      expect(src.calls, 1);
    },
  );

  testWidgets(
    'export finishing after background never reveals secrets on resume',
    (t) async {
      final source = PendingSource();
      await t.pumpWidget(app(ExportCodesPage(source: source)));
      await t.tap(find.text('Confirm with passkey'));
      await t.pump();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      source.result.complete([acct('secret')]);
      await t.pumpAndSettle();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.textContaining('QR code 1'), findsNothing);
      expect(find.text('Confirm with passkey'), findsOneWidget);
    },
  );

  testWidgets('transfer page: disabled export explains why', (t) async {
    await t.pumpWidget(
      app(
        TransferCodesPage(
          onScanImport: () {},
          onExport: () {},
          exportAvailability: (
            available: false,
            reason: 'Export is not available yet.',
          ),
        ),
      ),
    );
    expect(find.text('Import codes'), findsOneWidget);
    expect(find.text('Export is not available yet.'), findsOneWidget);
    expect(
      t.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );
  });

  testWidgets('review lists skipped entries and assumed parameters', (t) async {
    final o = ImportOutcome(
      [acct('one').withParameters()],
      [
        const SkippedEntry(
          2,
          OtpFormatError.unsupportedType,
          issuer: 'Bank',
          accountName: 'me',
        ),
      ],
    );
    final m = ImportReviewModel.fromOutcome(o);
    await t.pumpWidget(app(ImportReviewPage(model: m, saver: FakeSaver())));
    expect(find.textContaining('1 entry cannot be imported'), findsOneWidget);
    expect(find.textContaining('Bank (me): counter-based'), findsOneWidget);
  });

  testWidgets(
    'export: file save only after reauth, uses the chosen format, no save when adapter absent',
    (t) async {
      final saved = <(String, String)>[];
      var n = 0;
      await t.pumpWidget(
        app(
          ExportCodesPage(
            source: FakeSource([acct('a@example.com', issuer: 'GitHub')]),
            saveFile: (name, text) async {
              saved.add((name, text));
              return true;
            },
            newUuid: () =>
                '00000000-0000-4000-8000-${(n++).toString().padLeft(12, '0')}',
          ),
        ),
      );
      expect(find.text('Aegis'), findsNothing);
      await t.tap(find.text('Confirm with passkey'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Aegis'));
      await t.tap(find.text('Aegis'));
      await t.pumpAndSettle();
      expect(saved.single.$1, 'otpanda-aegis.json');
      expect(detectImportFile(saved.single.$2), ImportFileFormat.aegisPlain);
      expect(find.text('File saved.'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(ExportCodesPage(source: FakeSource([acct('a')]))));
      await t.tap(find.text('Confirm with passkey'));
      await t.pumpAndSettle();
      expect(find.text('Aegis'), findsNothing);
    },
  );
}
