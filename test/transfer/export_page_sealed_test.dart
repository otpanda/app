import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/transfer/export_entry.dart';
import 'package:otpanda_client/transfer/export_seal.dart';
import 'package:otpanda_client/transfer/sealed_export_source.dart';
import 'package:otpanda_client/transfer/transfer_pages.dart';

// Widget proof with the REAL SealedSeedExportSource and opener; only the
// network transport is faked. Secrets and keys are synthetic fixtures made by
// the API's own seal code.
Map<String, dynamic> _fixture(String n) =>
    jsonDecode(File('test/transfer/fixtures/$n').readAsStringSync())
        as Map<String, dynamic>;

Widget _app(Widget child) =>
    MaterialApp(theme: buildOtpandaTheme(Brightness.light), home: child);

final class _Transport implements ExportTransport {
  _Transport(this.s);
  final Map<String, dynamic> s;
  int begins = 0, finishes = 0;
  Completer<void>? beginGate, finishGate;

  @override
  Future<ExportBegin> begin({
    required String ephemeralKey,
    List<String>? entryIds,
  }) async {
    begins++;
    await beginGate?.future;
    return ExportBegin(
      ownerId: s['owner'] as String,
      deviceId: s['device'] as String,
      generation: s['generation'] as int,
      entries: [
        for (final e in (s['begin'] as List).cast<Map>())
          ApprovedExportEntry(
            entryId: e['entryId'] as String,
            version: e['version'] as String,
            label: e['label'] as String?,
            account: e['account'] as String?,
            issuer: e['issuer'] as String?,
            catalogId: e['catalogId'] as String?,
          ),
      ],
      unavailable: const [],
      handle: Object(),
    );
  }

  @override
  Future<Map<String, Object?>> finish({
    required ExportBegin begin,
    required String ephemeralKey,
  }) async {
    finishes++;
    await finishGate?.future;
    return jsonDecode(jsonEncode(s['response'])) as Map<String, Object?>;
  }
}

void main() {
  late Map<String, dynamic> s;
  setUp(() => s = _fixture('export-scenario.json'));

  ExportEphemeralKey key() => ExportEphemeralKey.fromScalarForTest(
    BigInt.parse(hex(unb64u(s['clientScalar'] as String)), radix: 16),
  );

  testWidgets('real source: success shows the QR and the disclosure', (
    t,
  ) async {
    final tr = _Transport(s);
    final k = key();
    await t.pumpWidget(
      _app(
        ExportCodesPage(entries: SealedSeedExportSource(tr, newKey: () => k)),
      ),
    );
    await t.tap(find.text('Confirm with passkey'));
    await t.pumpAndSettle();
    expect(find.textContaining('QR code 1 of 1'), findsOneWidget);
    expect(find.textContaining('45 s'), findsOneWidget);
    expect(k.disposed, isTrue, reason: 'key gone as soon as the reply opened');
  });

  testWidgets(
    'background while the passkey step is pending: late reply never displays',
    (t) async {
      final tr = _Transport(s)..finishGate = Completer<void>();
      final k = key();
      await t.pumpWidget(
        _app(
          ExportCodesPage(entries: SealedSeedExportSource(tr, newKey: () => k)),
        ),
      );
      await t.tap(find.text('Confirm with passkey'));
      await t.pump();
      await t.pump();
      expect(tr.finishes, 1);
      expect(k.disposed, isFalse);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(k.disposed, isTrue, reason: 'actual cancel hook disposed the key');
      tr.finishGate!.complete();
      await t.pumpAndSettle();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.textContaining('QR code 1'), findsNothing);
      expect(find.textContaining('Alpha'), findsNothing);
      expect(find.text('Confirm with passkey'), findsOneWidget);
    },
  );

  testWidgets(
    'leaving the page while begin is pending: no passkey step, nothing shown',
    (t) async {
      final tr = _Transport(s)..beginGate = Completer<void>();
      final k = key();
      await t.pumpWidget(
        _app(
          ExportCodesPage(entries: SealedSeedExportSource(tr, newKey: () => k)),
        ),
      );
      await t.tap(find.text('Confirm with passkey'));
      await t.pump();
      await t.pumpWidget(_app(const SizedBox()));
      expect(k.disposed, isTrue);
      tr.beginGate!.complete();
      await t.pumpAndSettle();
      expect(
        tr.finishes,
        0,
        reason: 'a dropped attempt never prompts a passkey',
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the page while the reply is pending: late reply dropped without error',
    (t) async {
      final tr = _Transport(s)..finishGate = Completer<void>();
      final k = key();
      await t.pumpWidget(
        _app(
          ExportCodesPage(entries: SealedSeedExportSource(tr, newKey: () => k)),
        ),
      );
      await t.tap(find.text('Confirm with passkey'));
      await t.pump();
      await t.pump();
      await t.pumpWidget(_app(const SizedBox()));
      tr.finishGate!.complete();
      await t.pumpAndSettle();
      expect(k.disposed, isTrue);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('odd names: QR is made with a caution, files keep raw text', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final w = _fixture('export-unrepresentable.json');
    final tr = _Transport(w);
    final k = ExportEphemeralKey.fromScalarForTest(
      BigInt.parse(hex(unb64u(w['clientScalar'] as String)), radix: 16),
    );
    final saved = <String, String>{};
    var n = 0;
    await t.pumpWidget(
      _app(
        ExportCodesPage(
          entries: SealedSeedExportSource(tr, newKey: () => k),
          saveFile: (name, text) async {
            saved[name] = text;
            return true;
          },
          newUuid: () =>
              '00000000-0000-4000-8000-${(n++).toString().padLeft(12, '0')}',
        ),
      ),
    );
    await t.tap(find.text('Confirm with passkey'));
    await t.pumpAndSettle();
    expect(find.textContaining('QR code 1 of 1'), findsOneWidget);
    expect(find.textContaining('No QR code was made'), findsNothing);
    expect(
      find.textContaining('may show these names differently'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Catalog links are not included'),
      findsOneWidget,
    );
    await t.tap(find.text('Aegis'));
    await t.pumpAndSettle();
    final aegis = jsonDecode(saved['otpanda-aegis.json']!) as Map;
    final first = ((aegis['db'] as Map)['entries'] as List).first as Map;
    expect(first['name'], 'a:b');
    expect(find.textContaining('File saved'), findsOneWidget);
    expect(
      find.textContaining('File saved. '),
      findsOneWidget,
      reason: 'save message lists what the file does not carry',
    );
  });

  for (final withSaver in [false, true]) {
    testWidgets(
      'malformed Unicode blocks the QR; file fallback offered only with a saver ($withSaver)',
      (t) async {
        await t.binding.setSurfaceSize(const Size(800, 3000));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final src = _OneShot([
          ExportedEntry(
            entryId: 'x',
            label: 'Bad\ud800',
            account: 'Bad\ud800',
            issuer: null,
            catalogId: null,
            algorithm: OtpAlgorithm.sha1,
            digits: 6,
            period: 30,
            secret: Uint8List(20),
          ),
        ]);
        await t.pumpWidget(
          _app(
            ExportCodesPage(
              entries: src,
              saveFile: withSaver ? (n, x) async => true : null,
              newUuid: withSaver ? () => 'u' : null,
            ),
          ),
        );
        await t.tap(find.text('Confirm with passkey'));
        await t.pumpAndSettle();
        expect(find.textContaining('QR code 1'), findsNothing);
        expect(find.textContaining('No QR code was made'), findsOneWidget);
        expect(
          find.textContaining('You can save a file instead'),
          withSaver ? findsOneWidget : findsNothing,
        );
        expect(find.text('Aegis'), withSaver ? findsOneWidget : findsNothing);
      },
    );
  }
}

final class _OneShot implements ExportEntrySource {
  _OneShot(this.entries);
  final List<ExportedEntry> entries;
  @override
  ({bool available, String? reason}) get availability =>
      (available: true, reason: null);
  @override
  Future<List<ExportedEntry>> exportEntries() async => entries;
}
