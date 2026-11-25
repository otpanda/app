import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/profile_header.dart';
import 'package:otpanda_client/settings_hub.dart';

import 'google_account_action_test.dart' show GoogleBridge;

Widget host(Widget child, {double width = 390}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets(
    'home avatar uses no third-party lookup and keeps initials on failure',
    (t) async {
      await t.pumpWidget(
        host(
          const ProfileAvatar(
            email: 'alex.murray@example.test',
            size: 32,
            allowGravatar: false,
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('AM'), findsOneWidget);
      await t.pumpWidget(
        host(
          const ProfileAvatar(
            email: 'alex.murray@example.test',
            size: 32,
            allowGravatar: false,
            googlePicture: 'https://lh3.googleusercontent.com/a/fail',
          ),
        ),
      );
      expect(
        (t.widget<Image>(find.byType(Image)).image as NetworkImage).url,
        contains('googleusercontent.com'),
      );
      await t.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('AM'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  test('sha256 matches the standard vectors', () {
    expect(
      sha256Hex(''),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
  });

  test('gravatar address uses the trimmed lowercase email and 404 default', () {
    expect(
      gravatarUrl('  Person@Example.COM '),
      gravatarUrl('person@example.com'),
    );
    expect(
      gravatarUrl('person@example.com'),
      startsWith('https://gravatar.com/avatar/'),
    );
    expect(gravatarUrl('person@example.com'), endsWith('&d=404'));
    expect(gravatarUrl('person@example.com'), isNot(contains('person')));
  });

  test('only Google picture hosts are accepted', () {
    expect(
      isGooglePicture('https://lh3.googleusercontent.com/a/x=s96-c'),
      isTrue,
    );
    for (final bad in [
      'http://lh3.googleusercontent.com/a',
      'https://evil.example/a',
      'https://googleusercontent.com.evil.example/a',
      'https://user@lh3.googleusercontent.com/a',
      null,
      5,
    ]) {
      expect(isGooglePicture(bad), isFalse, reason: '$bad');
    }
  });

  test('initials come from the address before the @', () {
    expect(initialsFor('alex.murray@example.test'), 'AM');
    expect(initialsFor('alex@example.test'), 'AL');
    expect(initialsFor('a@example.test'), 'A');
    expect(initialsFor('_.-@example.test'), '?');
  });

  testWidgets('loading holds the same height as the loaded header', (t) async {
    await t.pumpWidget(host(const ProfileHeader(email: null)));
    final loading = t.getSize(find.byType(ProfileHeader));
    await t.pumpWidget(host(const ProfileHeader(email: 'person@example.com')));
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(ProfileHeader)), loading);
  });

  testWidgets('loaded header is centred with initials while no picture loads', (
    t,
  ) async {
    await t.pumpWidget(
      host(const ProfileHeader(email: 'alex.murray@example.test')),
    );
    await t.pumpAndSettle();
    final email = find.text('alex.murray@example.test');
    expect(email, findsOneWidget);
    expect((t.widget<Text>(email)).textAlign, TextAlign.center);
    expect(
      t.getCenter(email).dx,
      closeTo(t.getCenter(find.byType(ProfileHeader)).dx, 1),
    );
    expect(find.text('AM'), findsOneWidget);
    // The picture request fails in tests; the initials stay.
    expect(t.takeException(), isNull);
  });

  testWidgets('a bad Google picture host is never requested, Gravatar is', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        const ProfileHeader(
          email: 'person@example.com',
          googlePicture: 'https://evil.example/a.png',
        ),
      ),
    );
    final urls = [
      for (final i in t.widgetList<Image>(find.byType(Image)))
        (i.image as NetworkImage).url,
    ];
    expect(urls.length, 1);
    expect(urls.single, startsWith('https://gravatar.com/avatar/'));
    await t.pumpAndSettle();
  });

  testWidgets('a Google picture is tried first and failure falls back', (
    t,
  ) async {
    const g = 'https://lh3.googleusercontent.com/a/example=s96-c';
    await t.pumpWidget(
      host(const ProfileHeader(email: 'person@example.com', googlePicture: g)),
    );
    String current() =>
        (t.widget<Image>(find.byType(Image)).image as NetworkImage).url;
    expect(current(), g);
    await t.pumpAndSettle();
    expect(find.text('PE'), findsOneWidget);
  });

  testWidgets(
    'settings hub: skeleton header keeps its place when the email arrives',
    (t) async {
      Widget hub({String? email, bool loading = false}) => MaterialApp(
        home: Scaffold(
          body: SettingsHub(
            selected: null,
            onSelect: (_) {},
            email: email,
            emailLoading: loading,
            pages: {SettingsCategory.account: const SizedBox()},
          ),
        ),
      );
      for (final size in [const Size(390, 800), const Size(1200, 800)]) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(hub(loading: true));
        final loading = t.getRect(find.byType(ProfileHeader));
        final tile = t.getRect(
          find.byKey(const Key('settings-settings/account-security')),
        );
        await t.pumpWidget(hub(email: 'person@example.com'));
        await t.pumpAndSettle();
        expect(find.text('person@example.com'), findsOneWidget);
        expect(t.getRect(find.byType(ProfileHeader)), loading);
        expect(
          t.getRect(
            find.byKey(const Key('settings-settings/account-security')),
          ),
          tile,
        );
      }
    },
  );

  testWidgets('settings page shows the profile header with the account email', (
    t,
  ) async {
    final b = GoogleBridge()..status = 'restored';
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          loginEnabled: true,
          navigation: 'settings/account-security',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(ProfileHeader), findsOneWidget);
    expect(find.text('same@example.test'), findsOneWidget);
    expect(find.text('SA'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
