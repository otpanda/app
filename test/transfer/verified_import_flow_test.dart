import 'package:otpanda_client/transfer/transfer_flow.dart';
import 'package:otpanda_client/transfer/import_review.dart';
import 'package:otpanda_client/transfer/batch_import_saver.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/import_recovery_journal.dart';
import 'package:otpanda_client/transfer/verified_import_flow.dart';

import 'batch_import_saver_test.dart' show Journal, Passkey;

void main() {
  setUpAll(() async {
    for (final entry in {
      'Figtree': [
        'Figtree-400.ttf',
        'Figtree-500.ttf',
        'Figtree-600.ttf',
        'Figtree-700.ttf',
      ],
      'BricolageGrotesque': [
        'BricolageGrotesque-700.ttf',
        'BricolageGrotesque-800.ttf',
      ],
    }.entries) {
      final font = FontLoader(entry.key);
      for (final file in entry.value) {
        font.addFont(
          Future.value(
            ByteData.sublistView(File('assets/fonts/$file').readAsBytesSync()),
          ),
        );
      }
      await font.load();
    }
  });

  final rec = ImportAttempt(
    ownerId: 'owner',
    deviceId: 'device',
    nonce: 'v2:${'A' * 32}',
    admissionId: 'B' * 32,
    count: 2,
  );
  testWidgets('startup terminal shown before explicit ack allows import', (
    t,
  ) async {
    final j = Journal()..value = rec;
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: buildOtpandaTheme(Brightness.light),
        home: Scaffold(
          body: VerifiedImportFlow(
            deviceId: 'device',
            current: () async => true,
            readSession: () async => (status: 200, body: '{"ownerId":"owner"}'),
            post: (p, b) async =>
                (status: 200, body: <String, dynamic>{'status': 'fenced'}),
            passkeys: Passkey(),
            journal: j,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('That import attempt was not saved.'), findsOneWidget);
    await t.runAsync(() async {
      final boundary = t.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
      );
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = Directory('build/test-evidence')
        ..createSync(recursive: true);
      await File('${output.path}/import-recovery-terminal-390.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(j.value?.outcome, 'fenced');
    expect(find.text('Scan import'), findsNothing);
    await t.tap(find.text('Got it'));
    await t.pumpAndSettle();
    expect(j.value, null);
    expect(find.text('That import attempt was not saved.'), findsNothing);
  });
  testWidgets('saved recovery remains acknowledgeable if refresh fails', (
    t,
  ) async {
    final j = Journal()..value = rec.terminal('saved');
    var refreshed = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: buildOtpandaTheme(Brightness.light),
        home: Scaffold(
          body: VerifiedImportFlow(
            deviceId: 'device',
            current: () async => true,
            readSession: () async => (status: 200, body: '{"ownerId":"owner"}'),
            post: (p, b) async =>
                (status: 200, body: <String, dynamic>{'status': 'saved'}),
            passkeys: Passkey(),
            journal: j,
            onSaved: () async {
              refreshed++;
              throw StateError('refresh');
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('was saved, but'), findsOneWidget);
    expect(find.text('Got it'), findsOneWidget);
    expect(j.value?.outcome, 'saved');
    expect(refreshed, 1);
    await t.tap(find.text('Got it'));
    await t.pumpAndSettle();
    expect(j.value, null);
    expect(t.takeException(), null);
  });
  testWidgets('foreign recovery blocks new work without wipe', (t) async {
    final j = Journal()..value = rec;
    var posts = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: buildOtpandaTheme(Brightness.light),
        home: Scaffold(
          body: VerifiedImportFlow(
            deviceId: 'different',
            current: () async => true,
            readSession: () async => (status: 200, body: '{"ownerId":"owner"}'),
            post: (p, b) async {
              posts++;
              return (status: 200, body: <String, dynamic>{'status': 'fenced'});
            },
            passkeys: Passkey(),
            journal: j,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.textContaining('different signed-in account or device'),
      findsOneWidget,
    );
    expect(find.text('Got it'), findsNothing);
    expect(j.value, rec);
    expect(posts, 0);
  });
  testWidgets('saved then Cancel returns recovery, retires saver until ack', (
    t,
  ) async {
    final j = Journal();
    BatchImportSaver? exposed;
    var begins = 0, finishes = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: buildOtpandaTheme(Brightness.light),
        home: Scaffold(
          body: VerifiedImportFlow(
            deviceId: 'device',
            current: () async => true,
            readSession: () async => (status: 200, body: '{"ownerId":"owner"}'),
            post: (p, b) async {
              if (p.endsWith('batch-begin')) {
                begins++;
                return (
                  status: 200,
                  body: <String, dynamic>{
                    'protocol': 2,
                    'admissionId': 'B' * 32,
                    'token': 'otpda_${'A' * 55}',
                    'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
                    'options': {
                      'challenge': 'A' * 43,
                      'rpId': 'otpanda.github.io',
                      'userVerification': 'required',
                      'timeout': 60000,
                      'allowCredentials': [
                        {'id': 'Y2lk', 'type': 'public-key'},
                      ],
                    },
                  },
                );
              }
              if (p.endsWith('batch-finish')) {
                finishes++;
                return (
                  status: 201,
                  body: <String, dynamic>{
                    'entryIds': ['one'],
                  },
                );
              }
              return (
                status: 200,
                body: <String, dynamic>{
                  'status': 'saved',
                  'entryIds': ['one'],
                },
              );
            },
            passkeys: Passkey(),
            journal: j,
            onSaver: (s) => exposed = s,
            readFile: () async => 'otpauth://totp/Synthetic:a?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Synthetic',
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(exposed, isNotNull);
    await t.tap(find.text('Import from file'));
    await t.pumpAndSettle();
    await t.tap(find.text('Import 1 account'));
    await t.pumpAndSettle();
    expect(find.text('Import saved.'), findsOneWidget);
    expect(j.value?.outcome, 'saved');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(exposed, isNull);
    expect(find.text('Your previous import was saved.'), findsOneWidget);
    expect(find.text('Import from file'), findsNothing);
    expect(begins, 1);
    expect(finishes, 1);
    await t.tap(find.text('Got it'));
    await t.pumpAndSettle();
    expect(j.value, null);
    expect(exposed, isNotNull);
    expect(find.text('Import from file'), findsOneWidget);
  });
  testWidgets(
    'refresh failure still retires review and runs recovery callback',
    (t) async {
      var closed = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: buildOtpandaTheme(Brightness.light),
          home: Scaffold(
            body: TransferFlow(
              saver: FakeFlowSaver(),
              readFile: () async => 'otpauth://totp/Synthetic:a?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Synthetic',
              onSaved: () async => throw StateError('refresh'),
              onReviewClosed: () async {
                closed++;
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Import from file'));
      await t.pumpAndSettle();
      await t.tap(find.text('Import 1 account'));
      await t.pumpAndSettle();
      await t.tap(find.text('Got it'));
      await t.pumpAndSettle();
      expect(closed, 1);
      expect(t.takeException(), null);
    },
  );
}

class FakeFlowSaver implements ImportSaver {
  @override
  bool get atomic => true;
  @override
  Future<ImportSaveOutcome> save(dynamic accounts) async =>
      ImportSaveOutcome.saved;
}
