import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/management_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/sharing_accept_page.dart';
import 'package:otpanda_client/sharing_contract.dart';

class FakeTransport implements ManagementTransport {
  final calls = <(String, Map<String, Object?>?)>[];
  final List<SessionResponse> replies;
  FakeTransport(this.replies);
  @override
  Future<SessionResponse> request(
    String path,
    String method,
    Map<String, Object?>? body,
  ) async {
    calls.add((path, body));
    return replies.removeAt(0);
  }
}

const token =
    'tok_abcdefghijklmnopqrstuvwxyz012345'; // 36 chars, valid pattern

Future<FakeTransport> open(
  WidgetTester t,
  List<SessionResponse> replies, {
  String routeToken = token,
  void Function()? onOpenCodes,
}) async {
  final rec = FakeTransport(replies);
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: otpandaTheme(),
      home: Scaffold(
        body: SharingAcceptPage(
          client: SharingClient(rec),
          token: routeToken,
          onOpenCodes: onOpenCodes,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return rec;
}

// Pixel captures need local fonts and are only taken on request:
// GOLDENS=1 flutter test --update-goldens test/sharing_accept_page_test.dart
final _shots = Platform.environment['GOLDENS'] == '1';

Future<void> _fonts() async {
  if (!_shots || !Platform.isLinux) return;
  for (final family in ['Figtree', 'BricolageGrotesque', 'MaterialIcons']) {
    final loader = FontLoader(family);
    final files = family == 'MaterialIcons'
        ? [
            '${Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ]
        : (family == 'Figtree' ? [400, 500, 600, 700] : [700, 800])
              .map((w) => 'assets/fonts/$family-$w.ttf')
              .toList();
    // Real rasterization is Linux-only; other platforms skip the files.
    for (final file in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(File(file).readAsBytesSync())),
      );
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_fonts);

  testWidgets('nothing is sent before a deliberate tap', (t) async {
    final rec = await open(t, []);
    expect(find.byKey(const Key('accept-confirm')), findsOneWidget);
    expect(rec.calls, isEmpty);
  });

  testWidgets('confirm accepts once and shows the granted scope', (t) async {
    var opened = 0;
    final rec = await open(
      t,
      [
        const SessionResponse(
          200,
          '{"ok":true,"mode":"allow","canDelegate":true}',
        ),
      ],
      onOpenCodes: () => opened++,
    );
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    expect(rec.calls, hasLength(1));
    expect(rec.calls.single.$1, '/v1/manage/sharing/invite/accept');
    expect(rec.calls.single.$2, {'token': token});
    final success = find.byKey(const Key('accept-success'));
    expect(success, findsOneWidget);
    final text = (t.widget(success) as Text).data!;
    expect(text, contains('Selected accounts were shared with you.'));
    expect(text, contains('machine profiles'));
    expect(text, isNot(contains(token)));
    // The done action navigates; it never re-accepts.
    await t.tap(find.byKey(const Key('accept-done')));
    await t.pumpAndSettle();
    expect(opened, 1);
    expect(rec.calls, hasLength(1));
  });

  testWidgets('success without delegation omits machine wording', (t) async {
    await open(t, [
      const SessionResponse(200, '{"ok":true,"mode":"all","canDelegate":false}'),
    ]);
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    final text = (t.widget(find.byKey(const Key('accept-success'))) as Text)
        .data!;
    expect(text, contains('All accounts were shared with you.'));
    expect(text, isNot(contains('machine profiles')));
    expect(find.byKey(const Key('accept-done')), findsNothing);
  });

  testWidgets('invalid route token is rejected without any network call', (
    t,
  ) async {
    final rec = await open(t, [], routeToken: 'short');
    expect(find.byKey(const Key('accept-invalid')), findsOneWidget);
    expect(find.byKey(const Key('accept-confirm')), findsNothing);
    expect(rec.calls, isEmpty);
  });

  testWidgets('unknown invite says invalid, expired or revoked', (t) async {
    final rec = await open(t, [const SessionResponse(404, '{}')]);
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    expect(
      find.text(
        'This invite link is invalid, expired or revoked. Ask the owner for a new one.',
      ),
      findsOneWidget,
    );
    expect(rec.calls, hasLength(1));
  });

  testWidgets('signed-out session asks to sign in first', (t) async {
    await open(t, [const SessionResponse(401, '{}')]);
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    expect(
      find.text('Sign in, then open the link again to accept.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed attempt can be retried and then succeeds', (t) async {
    final rec = await open(t, [
      const SessionResponse(429, '{}'),
      const SessionResponse(200, '{"ok":true,"mode":"deny","canDelegate":false}'),
    ]);
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('accept-retry')), findsOneWidget);
    await t.tap(find.byKey(const Key('accept-retry')));
    await t.pumpAndSettle();
    final text = (t.widget(find.byKey(const Key('accept-success'))) as Text)
        .data!;
    expect(text, contains('All except selected accounts'));
    expect(rec.calls, hasLength(2));
  });

  testWidgets('an unconfirmed result warns it may already have worked', (
    t,
  ) async {
    await open(t, [const SessionResponse(503, '{}')]);
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    final error = (t.widget(find.byKey(const Key('accept-error'))) as Text)
        .data!;
    expect(error, contains('may already have worked'));
  });

  testWidgets('pixels: ready, success and invalid states', (t) async {
    if (!_shots) return;
    await open(t, [
      const SessionResponse(200, '{"ok":true,"mode":"all","canDelegate":false}'),
    ]);
    await expectLater(
      find.byType(SharingAcceptPage),
      matchesGoldenFile('goldens/sharing_accept_ready.png'),
    );
    await t.tap(find.byKey(const Key('accept-confirm')));
    await t.pumpAndSettle();
    await expectLater(
      find.byType(SharingAcceptPage),
      matchesGoldenFile('goldens/sharing_accept_success.png'),
    );
  });

  testWidgets('pixels: damaged link', (t) async {
    if (!_shots) return;
    await open(t, [], routeToken: 'short');
    await expectLater(
      find.byType(SharingAcceptPage),
      matchesGoldenFile('goldens/sharing_accept_invalid.png'),
    );
  });
}
