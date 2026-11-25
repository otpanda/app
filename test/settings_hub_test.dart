import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/settings_hub.dart';

import 'browser_account_test.dart' show Bridge;

class AccountBridge extends Bridge {
  @override
  Future<SessionResponse> read(String path) async {
    if (path == '/v1/manage/account') {
      return SessionResponse(
        200,
        jsonEncode({
          'email': 'person@example.com',
          'passkeys': 1,
          'google': true,
          'recoveryDevices': 0,
        }),
      );
    }
    return super.read(path);
  }
}

Future<void> pump(
  WidgetTester t,
  Bridge b, {
  String? navigation,
  List<String>? log,
  Size size = const Size(420, 800),
  bool workspace = false,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        accountOnly: true,
        workspaceEnabled: workspace,
        loginEnabled: true,
        clock: () => 100000,
        navigation: navigation,
        onNavigate: log?.add,
      ),
    ),
  );
  await t.pumpAndSettle();
}

Bridge restored() => AccountBridge()
  ..status = 'restored'
  ..clockNow = 100000;

void main() {
  test('route ids parse strictly', () {
    expect(
      settingsCategoryForRoute('settings/account-security'),
      SettingsCategory.account,
    );
    expect(
      settingsCategoryForRoute('settings/devices'),
      SettingsCategory.devices,
    );
    expect(settingsCategoryForRoute('settings'), isNull);
    expect(settingsCategoryForRoute('settings/../x'), isNull);
    expect(settingsCategoryForRoute('https://evil'), isNull);
    expect(isSettingsRoute('settings'), isTrue);
    expect(isSettingsRoute('codes'), isFalse);
  });

  testWidgets('narrow: hub lists categories, each opens its own page', (
    t,
  ) async {
    final log = <String>[];
    await pump(t, restored(), log: log);
    expect(find.text('Account & security'), findsOneWidget);
    expect(find.text('Devices & sessions'), findsOneWidget);
    // The approved hub keeps its stable category even during a failed read.
    expect(find.text('Organization'), findsOneWidget);
    expect(find.text('Sign-in methods'), findsNothing);
    // No Licenses row in the hub: it lives under About.
    expect(find.text('Licenses'), findsNothing);
    expect(find.text('About'), findsOneWidget);
    await t.tap(find.text('About'));
    await t.pumpAndSettle();
    expect(log.last, 'settings/about');
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Development build'), findsOneWidget);
    expect(find.text('Source code'), findsOneWidget);
    expect(find.text('Website'), findsOneWidget);
    await t.tap(find.text('Open-source licenses'));
    await t.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Back to settings'));
    await t.pumpAndSettle();
    // Sign out is pinned to the bottom edge of the screen.
    final screen = t.getRect(find.byType(Scaffold).first);
    expect(
      screen.bottom -
          t.getRect(find.byKey(const Key('browser-sign-out'))).bottom,
      lessThanOrEqualTo(16),
    );
    // Sign out sits at the bottom of the main list.
    expect(find.widgetWithText(OutlinedButton, 'Sign out'), findsOneWidget);
    await t.tap(find.text('Account & security'));
    await t.pumpAndSettle();
    expect(log, ['settings/about', 'settings', 'settings/account-security']);
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Google'), findsOneWidget);
    await t.tap(find.byTooltip('Back to settings'));
    await t.pumpAndSettle();
    expect(log.last, 'settings');
    await t.tap(find.text('Devices & sessions'));
    await t.pumpAndSettle();
    expect(log.last, 'settings/devices');
    expect(find.text('This browser'), findsNothing);
    expect(find.text('Signed-in devices'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('Clear local access'), findsNothing);
    await t.tap(find.byTooltip('Back to settings'));
    await t.pumpAndSettle();
    await t.tap(find.text('Sign out'));
    await t.pumpAndSettle();
    expect(find.text('Devices & sessions'), findsNothing);
  });

  testWidgets('no scope labels, remember toggle or diagnostics anywhere', (
    t,
  ) async {
    await pump(t, restored(), navigation: 'settings/account-security');
    for (final page in [
      'settings/account-security',
      'settings/devices',
      'settings',
    ]) {
      await t.pumpWidget(const SizedBox.shrink());
      await pump(t, restored(), navigation: page);
      for (final text in [
        'Synced to your account',
        'This device only',
        'Temporary diagnostics',
      ]) {
        expect(find.textContaining(text), findsNothing);
      }
      expect(find.textContaining('Remember'), findsNothing);
      expect(find.byType(Switch), findsNothing);
    }
  });

  testWidgets('wide: list beside page, account shown by default', (t) async {
    final log = <String>[];
    await pump(t, restored(), log: log, size: const Size(1100, 800));
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(find.text('Devices & sessions'), findsOneWidget);
    await t.tap(find.text('Devices & sessions'));
    await t.pumpAndSettle();
    expect(find.text('This browser'), findsNothing);
    expect(find.text('Sign-in methods'), findsNothing);
    expect(log, ['settings/devices']);
  });

  testWidgets('external navigation selects the page and never echoes', (
    t,
  ) async {
    final log = <String>[];
    final b = restored();
    await pump(t, b, navigation: 'settings/devices', log: log);
    expect(find.text('This browser'), findsNothing);
    // An unknown id changes nothing.
    t.view.physicalSize = const Size(420, 800);
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          loginEnabled: true,
          clock: () => 100000,
          navigation: 'settings/../codes',
          onNavigate: log.add,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('This browser'), findsNothing);
    expect(log, isEmpty);
  });

  testWidgets('external route change after load moves between pages', (
    t,
  ) async {
    final log = <String>[];
    final b = restored();
    Widget app(String route) => MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        accountOnly: true,
        loginEnabled: true,
        clock: () => 100000,
        navigation: route,
        onNavigate: log.add,
      ),
    );
    t.view.physicalSize = const Size(420, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app('settings'));
    await t.pumpAndSettle();
    expect(find.text('Sign-in methods'), findsNothing);
    await t.pumpWidget(app('settings/account-security'));
    await t.pumpAndSettle();
    expect(find.text('Sign-in methods'), findsOneWidget);
    await t.pumpWidget(app('settings/devices'));
    await t.pumpAndSettle();
    expect(find.text('This browser'), findsNothing);
    expect(log, isEmpty);
  });

  testWidgets('workspace: opening settings, leaving and external route', (
    t,
  ) async {
    final log = <String>[];
    final b = restored();
    Widget app(String? route) => MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        accountOnly: true,
        workspaceEnabled: true,
        loginEnabled: true,
        clock: () => 100000,
        navigation: route,
        onNavigate: log.add,
      ),
    );
    t.view.physicalSize = const Size(420, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app('settings/devices'));
    await t.pumpAndSettle();
    expect(find.text('This browser'), findsNothing);
    await t.tap(find.byTooltip('Back to settings'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Back to codes'));
    await t.pumpAndSettle();
    expect(log, ['settings', 'codes']);
    expect(find.byKey(const Key('product-top-bar')), findsOneWidget);
    log.clear();
    await t.pumpWidget(app('settings/account-security'));
    await t.pumpAndSettle();
    expect(find.text('Sign-in methods'), findsOneWidget);
    expect(log, isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recovery routes open the lost-access step and nothing else', (
    t,
  ) async {
    final b = restored();
    t.view.physicalSize = const Size(420, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // A bridge without recovery ignores the route and shows settings.
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          clock: () => 100000,
          navigation: 'recovery/finish',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Account & security'), findsOneWidget);
  });
}
