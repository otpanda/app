// Widget tests for the approval prompt UI. The real-font render below is a
// widget-test render, not a device capture. Only taken on request:
//   GOLDENS=1 flutter test --update-goldens test/native/native_approval_prompt_test.dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/native/native_approval_prompt.dart';
import 'package:otpanda_client/native/native_approval_routes.dart';

const _now = 1000000;
final _target = 'abcdef0123456789${'0' * 48}';

ApprovalStatus _status(List<Map<String, dynamic>> rows) =>
    parseApprovalStatus({'ownerId': 'O', 'generation': 1, 'pending': rows})!;

Map<String, dynamic> _row(
  String id,
  String kind, {
  String? label,
  String rk = 'web',
  int ago = 180000,
}) => {
  'changeId': id,
  'kind': kind,
  'target': kind == 'device-key-add' ? _target : null,
  'requesterLabel': label,
  'requesterKind': rk,
  'requestedAt': _now - ago,
  'expiresAt': _now - ago + 600000,
};

Future<void> _fonts() async {
  Future<void> load(String family, List<String> paths) async {
    final l = FontLoader(family);
    for (final p in paths) {
      l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
    }
    await l.load();
  }

  await load('Figtree', [
    'assets/fonts/Figtree-400.ttf',
    'assets/fonts/Figtree-500.ttf',
    'assets/fonts/Figtree-600.ttf',
    'assets/fonts/Figtree-700.ttf',
  ]);
  await load('BricolageGrotesque', [
    'assets/fonts/BricolageGrotesque-700.ttf',
    'assets/fonts/BricolageGrotesque-800.ttf',
  ]);
  await load('MaterialIcons', [
    '${Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

Widget _app(
  ApprovalStatus s, {
  void Function(ApprovalRow)? ok,
  void Function(ApprovalRow)? no,
  int Function()? clock,
}) => MaterialApp(
  theme: otpandaTheme(),
  home: Scaffold(
    body: ApprovalListView(
      status: s,
      accountEmail: 'abraham@example.com',
      clock: clock ?? () => _now,
      onApprove: ok ?? (_) {},
      onDismiss: no ?? (_) {},
    ),
  ),
);

void main() {
  testWidgets(
    'shows requester kind, age, 16-hex fingerprint and the only-if-you-started-this warning; buttons call back',
    (t) async {
      final s = _status([
        _row('C1', 'passkey-add'),
        _row(
          'C2',
          'device-key-add',
          label: 'Pixel 8',
          rk: 'android',
          ago: 30000,
        ),
      ]);
      final approved = <String>[], declined = <String>[];
      await t.pumpWidget(
        _app(
          s,
          ok: (r) => approved.add(r.changeId),
          no: (r) => declined.add(r.changeId),
        ),
      );
      expect(
        find.textContaining('Requested 3 minutes ago from a browser'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Only approve if you started this'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Requested just now from an Android phone (Pixel 8)',
        ),
        findsOneWidget,
      );
      expect(find.text('abcd-ef01-2345-6789'), findsOneWidget);
      await t.tap(find.text('Approve').last);
      await t.tap(find.text('Dismiss').first);
      expect(approved, ['C2']);
      expect(declined, ['C1']);
    },
  );

  testWidgets(
    'an unsafe label disables Approve and says why; no raw text is shown',
    (t) async {
      final s = _status([_row('C1', 'passkey-add', label: 'Pi\u202Exel')]);
      await t.pumpWidget(_app(s));
      expect(find.textContaining('could not be shown safely'), findsOneWidget);
      expect(find.textContaining('Pi'), findsNothing);
      final b = t.widget<FilledButton>(find.byType(FilledButton));
      expect(b.onPressed, isNull);
    },
  );

  testWidgets('real-font render (widget-test render, not device pixels)', (
    t,
  ) async {
    await _fonts();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = _status([
      _row('C2', 'device-key-add', label: 'Pixel 8', rk: 'android', ago: 90000),
      _row('C1', 'passkey-add', label: 'Firefox on Linux'),
    ]);
    await t.pumpWidget(_app(s));
    await t.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/native_approval_prompt_390.png'),
    );
  }, skip: Platform.environment['GOLDENS'] != '1');

  testWidgets(
    'time moves: ages update and expired rows drop on tick; dismiss is local, says the request stays open',
    (t) async {
      var now = _now;
      final s = _status([_row('C1', 'passkey-add')]);
      final dismissed = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: Scaffold(
            body: ApprovalListView(
              status: s,
              accountEmail: 'a@b.io',
              clock: () => now,
              onApprove: (_) {},
              onDismiss: (r) => dismissed.add(r.changeId),
              tick: const Duration(seconds: 1),
            ),
          ),
        ),
      );
      expect(find.textContaining('3 minutes ago'), findsOneWidget);
      expect(
        find.textContaining('stays open until it expires'),
        findsOneWidget,
      );
      now += 120000; // 5 minutes
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('5 minutes ago'), findsOneWidget);
      now += 600000; // past expiry
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('minutes ago'), findsNothing);
      expect(find.text('Nothing is waiting for approval.'), findsOneWidget);
      expect(dismissed, isEmpty);
    },
  );

  testWidgets(
    'already expired rows are never shown; Dismiss hides locally and reports nothing sent',
    (t) async {
      final s = _status([
        _row('C1', 'passkey-add', ago: 599000),
        _row('C2', 'passkey-add'),
      ]);
      final dismissed = <String>[];
      await t.pumpWidget(
        _app(s, no: (r) => dismissed.add(r.changeId), clock: () => _now + 2000),
      );
      expect(find.text('Dismiss'), findsOneWidget);
      await t.tap(find.text('Dismiss'));
      await t.pump();
      expect(dismissed, ['C2']);
      expect(find.text('Dismiss'), findsNothing);
    },
  );
}
