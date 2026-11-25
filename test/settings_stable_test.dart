import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';

import '../tool/preview/account_main.dart' as preview;

import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/google_link.dart';
import 'package:otpanda_client/recovery_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/settings_hub.dart';

import 'settings_hub_test.dart' show AccountBridge, pump;

class RefusingBridge extends LinkBridge {
  @override
  Future<void> disconnectGoogle() async => throw const RecoveryRefused();
}

class NoPasskeyBridge extends LinkBridge {
  @override
  Future<SessionResponse> read(String path) async =>
      path == '/v1/manage/account'
      ? SessionResponse(
          200,
          jsonEncode({
            'email': 'person@example.com',
            'passkeys': 0,
            'google': true,
            'recoveryDevices': 0,
          }),
        )
      : super.read(path);
}

class LinkBridge extends AccountBridge
    implements GoogleLinkBridge, AdditionalPasskeyBridge {
  int unlinks = 0, adds = 0;
  @override
  bool get googleDisconnectAvailable => true;
  @override
  Future<void> disconnectGoogle() async => unlinks++;
  @override
  Future<void> addPasskey() async => adds++;
}

LinkBridge linked() => LinkBridge()
  ..status = 'restored'
  ..clockNow = 100000;

void main() {
  stableTests();
  testWidgets('settings tiles size to content, not a fixed height', (t) async {
    await pump(t, linked(), navigation: 'settings/account-security');
    final h = t.getSize(find.widgetWithText(Card, 'Sign-in methods').first);
    expect(h.height, lessThan(260));
  });

  testWidgets('skeleton bars are one text line tall', (t) async {
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: RedactedText('x'))),
    );
    expect(t.getSize(find.byType(RedactedText)).height, greaterThan(10));
  });

  testWidgets('passkeys row opens its own page with an add button', (t) async {
    final log = <String>[];
    final b = linked();
    await pump(t, b, navigation: 'settings/account-security', log: log);
    await t.tap(find.byKey(const Key('settings-passkeys-row')));
    await t.pumpAndSettle();
    expect(log.last, settingsPasskeysRoute);
    expect(find.byKey(const Key('add-passkey-fab')), findsOneWidget);
    await t.tap(find.byKey(const Key('add-passkey-fab')));
    await t.pumpAndSettle();
    expect(b.adds, 1);
    await t.tap(find.byTooltip('Back to account and security'));
    await t.pumpAndSettle();
    expect(log.last, 'settings/account-security');
    expect(find.byKey(const Key('add-passkey-fab')), findsNothing);
  });

  testWidgets('direct passkeys route opens the page', (t) async {
    await pump(t, linked(), navigation: settingsPasskeysRoute);
    expect(find.byKey(const Key('add-passkey-fab')), findsOneWidget);
  });

  testWidgets('Google disconnect needs confirmation; cancel changes nothing', (
    t,
  ) async {
    final b = linked();
    await pump(t, b, navigation: 'settings/account-security');
    await t.tap(find.text('Disconnect'));
    await t.pumpAndSettle();
    expect(find.text('Disconnect Google?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(b.unlinks, 0);
    await t.tap(find.text('Disconnect'));
    await t.pumpAndSettle();
    await t.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Disconnect'),
      ),
    );
    await t.pumpAndSettle();
    expect(b.unlinks, 1);
  });

  testWidgets('a refusal is generic and the page says what is true', (t) async {
    final b = RefusingBridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await pump(t, b, navigation: 'settings/account-security');
    await t.tap(find.text('Disconnect'));
    await t.pumpAndSettle();
    await t.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Disconnect'),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('Google was not disconnected'), findsOneWidget);
  });

  testWidgets('Disconnect is disabled with no passkeys and never calls out', (
    t,
  ) async {
    final b = NoPasskeyBridge()
      ..status = 'restored'
      ..clockNow = 100000;
    await pump(t, b, navigation: 'settings/account-security');
    final button = find.widgetWithText(OutlinedButton, 'Disconnect');
    expect(button, findsOneWidget);
    expect(t.widget<OutlinedButton>(button).onPressed, isNull);
    expect(find.textContaining('Add a passkey to disconnect'), findsOneWidget);
    await t.tap(button, warnIfMissed: false);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(b.unlinks, 0);
  });

  testWidgets('confirmation stays compact on a wide screen', (t) async {
    await pump(
      t,
      linked(),
      navigation: 'settings/account-security',
      size: const Size(1600, 900),
    );
    await t.tap(find.text('Disconnect'));
    await t.pumpAndSettle();
    final w = t
        .getSize(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Material),
              )
              .first,
        )
        .width;
    expect(w, lessThanOrEqualTo(400));
    expect(w, greaterThan(250));
  });

  testWidgets('confirmation fits a narrow phone', (t) async {
    await pump(
      t,
      linked(),
      navigation: 'settings/account-security',
      size: const Size(320, 640),
    );
    await t.tap(find.text('Disconnect'));
    await t.pumpAndSettle();
    expect(
      t
          .getSize(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(Material),
                )
                .first,
          )
          .width,
      lessThanOrEqualTo(320),
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('no Disconnect without a bridge capability', (t) async {
    await pump(t, restoredPlain(), navigation: 'settings/account-security');
    expect(find.text('Disconnect'), findsNothing);
  });
}

AccountBridge restoredPlain() => AccountBridge()
  ..status = 'restored'
  ..clockNow = 100000;

class _Page extends StatelessWidget {
  const _Page();
  @override
  Widget build(BuildContext context) => BrowserAccountPage(
    bridge: preview.Fake(),
    loginEnabled: true,
    workspaceEnabled: false,
    accountOnly: true,
    navigation: 'settings/account-security',
  );
}

void stableHeights(
  String name,
  Size size, {
  required bool google,
  required bool protection,
  required bool escape,
}) {
  testWidgets(
    'cards keep the same bounds loading vs loaded ($name, google=$google, protection=$protection, email-only=$escape)',
    (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      preview.previewGoogle = google;
      preview.previewProtection = protection;
      preview.previewEscape = escape;
      addTearDown(() {
        preview.previewGoogle = true;
        preview.previewProtection = true;
        preview.previewEscape = true;
      });
      preview.gate = Completer<void>();
      await t.pumpWidget(MaterialApp(home: const _Page()));
      await t.pump(const Duration(milliseconds: 300));
      Rect card(String title) => t.getRect(
        find.ancestor(of: find.text(title), matching: find.byType(Card)).first,
      );
      final loading = [card('Sign-in methods'), card('Protection')];
      preview.gate!.complete();
      preview.gate = null;
      await t.pumpAndSettle();
      final loaded = [card('Sign-in methods'), card('Protection')];
      for (var i = 0; i < 2; i++) {
        expect(loaded[i].top, loading[i].top, reason: 'card $i top');
        expect(loaded[i].height, loading[i].height, reason: 'card $i height');
      }
    },
  );
}

void stableTests() {
  for (final w in [(390.0, 844.0), (1200.0, 800.0)]) {
    for (final g in [true, false]) {
      for (final p in [true, false]) {
        for (final e in [true, false]) {
          stableHeights(
            '${w.$1.toInt()}',
            Size(w.$1, w.$2),
            google: g,
            protection: p,
            escape: e,
          );
        }
      }
    }
  }
}
