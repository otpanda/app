import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_batch.dart';
import 'package:otpanda_client/totp_enrollment.dart';

const serverStart = 1800000010000;

class Bridge
    implements BrowserSessionBridge, TotpManagementBridge, TotpBatchBridge {
  int singles = 0, batches = 0, batchStatus = 200;
  List<String> omitted = [];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<SessionResponse> read(String path) async => SessionResponse(
    200,
    jsonEncode({'ownerId': 'o', 'expiresAt': serverStart + 3600000}),
  );
  @override
  Future<SessionResponse> totpCode(String entryId) async {
    singles++;
    final start = serverStart ~/ 30000 * 30;
    return SessionResponse(
      200,
      jsonEncode({
        'entryId': entryId,
        'code': '999999',
        'period': 30,
        'validFrom': start,
        'validUntil': start + 30,
        'serverNow': serverStart,
      }),
    );
  }

  @override
  Future<SessionResponse> totpCodes(List<String> ids) async {
    batches++;
    if (batchStatus != 200) return SessionResponse(batchStatus, '{}');
    final from = serverStart ~/ 30000 * 30;
    return SessionResponse(
      200,
      jsonEncode({
        'serverNow': serverStart,
        'windowSeconds': 600,
        'windowExpiresAt': serverStart + 600000,
        'entries': [
          for (final id in ids.where((i) => !omitted.contains(i)))
            {
              'entryId': id,
              'period': 30,
              'digits': 6,
              'validFrom': from,
              'codes': [for (var i = 0; i < 21; i++) '${100000 + i}'],
            },
        ],
        'omitted': [
          for (final id in ids.where(omitted.contains))
            {'entryId': id, 'reason': 'period_too_short'},
        ],
      }),
    );
  }
}

void main() {
  late int mono;
  TotpBatchStore storeFor(Bridge b) => TotpBatchStore(
    fetch: b.totpCodes,
    monotonicMilliseconds: () => mono,
    sessionExpiresAt: () async => serverStart + 3600000,
  );
  setUp(() => mono = 1000);

  Future<void> open(WidgetTester t, Bridge b, TotpBatchStore? s, String id) =>
      t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TotpEntryDialog(bridge: b, entryId: id, batch: s),
          ),
        ),
      );

  testWidgets(
    'a batched code shows at once, ticks locally, makes no single request',
    (t) async {
      final b = Bridge(), s = storeFor(b);
      await s.ensure(['a', 'b']);
      expect(b.batches, 1);
      await open(t, b, s, 'a');
      expect(find.text('100000'), findsOneWidget);
      expect(find.text('Expires in 20 seconds'), findsOneWidget);
      mono += 21000;
      await t.pump(const Duration(seconds: 1));
      expect(find.text('100001'), findsOneWidget);
      expect(b.singles, 0);
      expect(b.batches, 1);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'opening an entry the batch lacks asks once, with the others kept',
    (t) async {
      final b = Bridge(), s = storeFor(b);
      await s.ensure(['a']);
      await open(t, b, s, 'new');
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.text('100000'), findsOneWidget);
      expect(b.batches, 2);
      expect(b.singles, 0);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an entry the server omitted falls back to one code at a time', (
    t,
  ) async {
    final b = Bridge()..omitted = ['fast'];
    final s = storeFor(b);
    await s.ensure(['a', 'fast']);
    await open(t, b, s, 'fast');
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(b.singles, 1);
    expect(find.text('999999'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('without a batch store the dialog works as before', (t) async {
    final b = Bridge();
    await open(t, b, null, 'a');
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(b.singles, 1);
    expect(b.batches, 0);
    expect(find.text('999999'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a cleared batch shows no code', (t) async {
    final b = Bridge(), s = storeFor(b);
    await s.ensure(['a']);
    await open(t, b, s, 'a');
    s.clear();
    await t.pump(const Duration(seconds: 1));
    expect(find.text('100000'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a batch route that fails falls back to one code and no error', (
    t,
  ) async {
    for (final status in [404, 500]) {
      final b = Bridge()..batchStatus = status;
      final s = storeFor(b);
      await open(t, b, s, 'a');
      await t.pump();
      await t.pump(const Duration(seconds: 1));
      expect(find.text('999999'), findsOneWidget, reason: '$status');
      expect(b.singles, 1);
      expect(find.textContaining('Waiting for your connection'), findsNothing);
      await t.pumpWidget(const SizedBox());
    }
  });
}
