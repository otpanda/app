import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/offline_totp/otpauth_uri.dart';
import 'package:otpanda_client/offline_totp/import_outcome.dart';
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

Widget app(Widget child) =>
    MaterialApp(theme: buildOtpandaTheme(Brightness.light), home: child);

void main() {
  testWidgets(
    'throwing acknowledgement keeps review open with retained-record feedback',
    (t) async {
      final saver = ThrowingAckSaver();
      await t.pumpWidget(
        app(
          ImportReviewPage(
            model: ImportReviewModel([acct('one')]),
            saver: saver,
          ),
        ),
      );
      await t.tap(find.text('Import 1 account'));
      await t.pumpAndSettle();
      await t.tap(find.text('Got it'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('recovery record has been kept'),
        findsOneWidget,
      );
      expect(find.byType(ImportReviewPage), findsOneWidget);
      expect(t.takeException(), null);
      expect(saver.acks, 1);
    },
  );

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
    expect(result, false); // Still on the page until the outcome is seen.
    expect(find.text('Import saved.'), findsOneWidget);
    await t.tap(find.text('Got it'));
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
}

class ThrowingAckSaver extends FakeSaver
    implements RecoverableImportSaver, ImportAcknowledgementSource {
  int acks = 0;
  @override
  Future<ImportSaveOutcome> reconcile() async => ImportSaveOutcome.saved;
  @override
  Future<bool> acknowledgeShown() async {
    acks++;
    throw PlatformException(code: 'storage_unavailable');
  }

  @override
  Future<bool> Function() captureShownAcknowledgement() => acknowledgeShown;
}
