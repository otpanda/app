import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/offline_totp/import_outcome.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/transfer/import_review.dart';
import 'package:otpanda_client/transfer/transfer_pages.dart';
import 'package:otpanda_client/transfer/universal_scanner.dart';

import 'transfer_test.dart' show FakeSaver, FakeSource, acct;

// Renders to PNG for review: flutter test --update-goldens test/transfer/transfer_visual_test.dart
Future<void> _fonts() async {
  for (final family in ['Figtree', 'BricolageGrotesque', 'MaterialIcons']) {
    final files = family == 'MaterialIcons'
        ? [
            '/downloads/otpanda/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ]
        : (family == 'Figtree' ? [400, 500, 600, 700] : [700, 800])
              .map((w) => 'assets/fonts/$family-$w.ttf')
              .toList();
    final loader = FontLoader(family);
    for (final path in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
      );
    }
    await loader.load();
  }
}

final _skip = Platform.environment['TRANSFER_SHOTS'] == null
    ? 'set TRANSFER_SHOTS=1 to render'
    : null;

void main() {
  if (_skip != null) {
    test('renders PNGs', () {}, skip: _skip);
    return;
  }
  setUpAll(_fonts);
  Widget app(Widget c) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildOtpandaTheme(Brightness.light),
    home: c,
  );
  Future<void> shot(WidgetTester t, String name, Widget w) async {
    t.view.physicalSize = const Size(390 * 2, 800 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(w));
    await t.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/$name.png'),
    );
  }

  testWidgets(
    'transfer page',
    (t) async => shot(
      t,
      'transfer_codes',
      Scaffold(
        appBar: AppBar(title: const Text('Transfer codes')),
        body: TransferCodesPage(
          onScanImport: () {},
          onExport: () {},
          onImportFile: () {},
          exportAvailability: (available: true, reason: null),
        ),
      ),
    ),
  );
  testWidgets(
    'review',
    (t) async => shot(
      t,
      'import_review',
      ImportReviewPage(
        model: ImportReviewModel(
          [
            acct('ana@example.com', issuer: 'GitHub'),
            acct('bob@example.com', issuer: 'Google', fill: 2),
            acct('old@example.com', issuer: 'Example', fill: 3, period: 60),
          ],
          existing: {('Google', 'bob@example.com')},
          skipped: const [
            SkippedEntry(
              4,
              OtpFormatError.unsupportedType,
              issuer: 'Bank',
              accountName: 'me',
            ),
          ],
        ),
        saver: FakeSaver(),
      ),
    ),
  );
  testWidgets(
    'scanner',
    (t) async => shot(
      t,
      'scanner',
      UniversalScannerPage(
        camera: (a, b) => const ColoredBox(color: Colors.black54),
      ),
    ),
  );
  testWidgets('export', (t) async {
    t.view.physicalSize = const Size(390 * 2, 800 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      app(
        ExportCodesPage(
          source: FakeSource([
            acct('ana@example.com', issuer: 'GitHub'),
            acct('slow@example.com', issuer: 'Example', period: 60),
          ]),
        ),
      ),
    );
    await t.tap(find.text('Confirm with passkey'));
    await t.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('shots/export.png'),
    );
  });
}
