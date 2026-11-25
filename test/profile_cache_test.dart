import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/google_link.dart';
import 'package:otpanda_client/profile_cache.dart';
import 'package:otpanda_client/profile_header.dart';
import 'package:otpanda_client/session_contract.dart';

import 'browser_account_test.dart' show Bridge;

final sid = 'a' * 64;

class CacheBridge extends Bridge implements ProfileCacheBridge {
  String? sessionId = 'a' * 64;
  String owner = 'owner-1';
  String stored = '';
  int overviews = 0, writes = 0;
  final readArgs = <String>[];
  String email = 'live@example.test';
  Completer<void>? gate;
  String? picture;
  bool google = false;
  int overviewStatus = 200;
  @override
  Future<SessionResponse> read(String path) async {
    if (path == '/v1/manage/session' ||
        path == '/v1/manage/session?view=cache-v1') {
      final view = path.contains('view');
      if (view && sessionId == null) return const SessionResponse(400, '{}');
      return SessionResponse(
        200,
        jsonEncode({
          'ownerId': owner,
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
          if (view) 'sessionId': sessionId,
        }),
      );
    }
    if (path == '/v1/manage/account') {
      overviews++;
      if (gate != null) await gate!.future;
      if (overviewStatus != 200) return SessionResponse(overviewStatus, '{}');
      return SessionResponse(
        200,
        jsonEncode({
          'email': email,
          'picture': ?picture,
          'passkeys': 1,
          'google': google,
          'recoveryDevices': 0,
        }),
      );
    }
    return super.read(path);
  }

  @override
  String profileRead(String ownerId, String sessionId) {
    readArgs.add('$ownerId/$sessionId');
    return stored;
  }

  @override
  void profileWrite(String o, String s, String e, String? p) {
    writes++;
    stored = jsonEncode({
      'email': e,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  void profileClear() => stored = '';
  @override
  bool profileRevoked = false;
  void Function()? revokeListener;
  @override
  void onProfileRevoked(void Function() listener) => revokeListener = listener;
  void revoke() {
    profileRevoked = true;
    stored = '';
    revokeListener?.call();
  }
}

Widget page(Bridge b, {String nav = 'settings/account-security'}) =>
    MaterialApp(
      home: BrowserAccountPage(
        bridge: b,
        accountOnly: true,
        loginEnabled: true,
        navigation: nav,
      ),
    );

class LinkBridge extends CacheBridge implements GoogleConnectBridge {
  String result = 'connected';
  @override
  bool get googleConnectAvailable => true;
  @override
  Future<String> connectGoogle() async => '';
  @override
  String takeGoogleLinkResult() {
    final r = result;
    result = '';
    return r;
  }
}

const pictureA = 'https://lh3.googleusercontent.com/a/A=s96-c';
const pictureB = 'https://lh3.googleusercontent.com/a/B=s96-c';
String cacheWith(String? picture) => jsonEncode({
  'email': 'live@example.test',
  'picture': ?picture,
  'savedAt': DateTime.now().millisecondsSinceEpoch,
});

void main() {
  testWidgets('home loads the signed-in avatar without opening settings', (
    t,
  ) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..email = 'alex.murray@example.test';
    await t.pumpWidget(
      MaterialApp(
        home: BrowserAccountPage(
          bridge: b,
          accountOnly: true,
          workspaceEnabled: true,
          loginEnabled: true,
          navigation: 'codes',
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(ProfileAvatar), findsOneWidget);
    expect(find.text('AM'), findsOneWidget);
    expect(t.getSize(find.byType(ProfileAvatar)), const Size(32, 32));
    expect(find.byTooltip('Account & security'), findsOneWidget);
    expect(find.byIcon(Icons.account_circle_outlined), findsNothing);
    expect(b.overviews, 1);
    await t.pump(const Duration(seconds: 35));
    await t.pumpAndSettle();
    expect(b.overviews, 1);
    await t.pumpWidget(const SizedBox());
    expect(t.takeException(), isNull);
  });

  test('parseCachedProfile accepts only the exact static shape', () {
    expect(parseCachedProfile(''), isNull);
    expect(parseCachedProfile('{"email":"a@b.test","savedAt":1}'), isNotNull);
    expect(parseCachedProfile('{"email":"a@b.test"}'), isNull);
    expect(
      parseCachedProfile('{"email":"a@b.test","savedAt":1,"x":1}'),
      isNull,
    );
    expect(
      parseCachedProfile(
        '{"email":"a@b.test","savedAt":1,"picture":"https://evil.test/x"}',
      ),
      isNull,
    );
    expect(parseCachedProfile('nope'), isNull);
  });

  testWidgets('first visit loads the overview and writes the cache', (t) async {
    final b = CacheBridge()..status = 'restored';
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(find.text('live@example.test'), findsWidgets);
    expect(b.overviews, 1);
    expect(b.writes, 1);
    expect(b.readArgs, ['owner-1/$sid']);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('cached header shows at once for the same session', (t) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..stored = jsonEncode({
        'email': 'cached@example.test',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      })
      ..gate = Completer<void>();
    await t.pumpWidget(page(b));
    await t.pump();
    await t.pump();
    expect(find.text('cached@example.test'), findsWidgets);
    b.gate!.complete();
    await t.pumpAndSettle();
    // The account page is on screen, so the live overview replaces it.
    expect(find.text('live@example.test'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('API without sessionId: no cache read, page still works', (
    t,
  ) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..sessionId = null
      ..stored = jsonEncode({
        'email': 'stale@example.test',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      });
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(b.readArgs, isEmpty);
    expect(find.text('stale@example.test'), findsNothing);
    expect(find.text('live@example.test'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('malformed sessionId means no cache, page still loads', (
    t,
  ) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..sessionId = 'XYZ';
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(b.readArgs, isEmpty);
    expect(b.overviews, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('narrow hub root with a fresh cache makes no overview request', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final b = CacheBridge()
      ..status = 'restored'
      ..stored = jsonEncode({
        'email': 'cached@example.test',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      });
    await t.pumpWidget(page(b, nav: 'settings'));
    await t.pumpAndSettle();
    expect(b.overviews, 0);
    expect(find.text('cached@example.test'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('stale cache still triggers a refresh', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final b = CacheBridge()
      ..status = 'restored'
      ..stored = jsonEncode({
        'email': 'cached@example.test',
        'savedAt': DateTime.now().millisecondsSinceEpoch - 90000000,
      });
    await t.pumpWidget(page(b, nav: 'settings'));
    await t.pumpAndSettle();
    expect(b.overviews, 1);
    await t.pumpWidget(const SizedBox());
  });

  Finder googleImage() => find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is NetworkImage &&
        (w.image as NetworkImage).url.contains('googleusercontent'),
  );

  testWidgets(
    'cached picture shows first, live overview without one replaces it',
    (t) async {
      final b = CacheBridge()
        ..status = 'restored'
        ..stored = jsonEncode({
          'email': 'cached@example.test',
          'picture': 'https://lh3.googleusercontent.com/a/x=s96-c',
          'savedAt': DateTime.now().millisecondsSinceEpoch,
        })
        ..gate = Completer<void>();
      await t.pumpWidget(page(b));
      await t.pump();
      await t.pump();
      expect(googleImage(), findsWidgets);
      b.gate!.complete();
      await t.pumpAndSettle();
      // Google was unlinked since: the live overview has no picture.
      expect(googleImage(), findsNothing);
      expect(b.writes, 1);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('another tab revoking drops the cached header', (t) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..stored = jsonEncode({
        'email': 'cached@example.test',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      })
      ..gate = Completer<void>();
    await t.pumpWidget(page(b));
    await t.pump();
    await t.pump();
    expect(find.text('cached@example.test'), findsWidgets);
    b.revoke();
    await t.pump();
    expect(find.text('cached@example.test'), findsNothing);
    b.gate!.complete();
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a revoked bridge never shows a cache', (t) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..profileRevoked = true
      ..stored = jsonEncode({
        'email': 'cached@example.test',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      })
      ..gate = Completer<void>();
    await t.pumpWidget(page(b));
    await t.pump();
    await t.pump();
    expect(find.text('cached@example.test'), findsNothing);
    expect(b.readArgs, isEmpty);
    b.gate!.complete();
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('revocation shows the skeleton at once, then converges', (
    t,
  ) async {
    final b = CacheBridge()..status = 'restored';
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(find.text('live@example.test'), findsWidgets);
    b.gate = Completer<void>();
    b.revoke();
    await t.pump();
    expect(find.text('live@example.test'), findsNothing);
    b.gate!.complete();
    await t.pumpAndSettle();
    expect(find.text('live@example.test'), findsWidgets);
    expect(b.overviews, 2);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sign out with a cache bridge clears the page and signs out', (
    t,
  ) async {
    final b = CacheBridge()..status = 'restored';
    await t.pumpWidget(
      MaterialApp(home: BrowserAccountPage(bridge: b, loginEnabled: true)),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Sign out'));
    await t.pumpAndSettle();
    expect(b.logouts, 1);
    expect(find.text('live@example.test'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('an ordinary overview refresh does not revoke anything', (
    t,
  ) async {
    final b = CacheBridge()..status = 'restored';
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(b.profileRevoked, false);
    expect(b.writes, 1);
    expect(find.text('live@example.test'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  Finder imageUrl(String u) => find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is NetworkImage &&
        (w.image as NetworkImage).url == u,
  );

  testWidgets(
    'connect return: cached picture A is dropped, live B is written',
    (t) async {
      final b = LinkBridge()
        ..status = 'restored'
        ..google = true
        ..picture = pictureB
        ..stored = cacheWith(pictureA)
        ..gate = Completer<void>();
      await t.pumpWidget(page(b));
      await t.pump();
      await t.pump();
      expect(imageUrl(pictureA), findsNothing);
      expect(find.text('Google connected.'), findsNothing);
      b.gate!.complete();
      var sawB = false;
      for (var i = 0; i < 10; i++) {
        await t.pump();
        expect(imageUrl(pictureA), findsNothing);
        if (imageUrl(pictureB).evaluate().isNotEmpty) sawB = true;
      }
      expect(sawB, true);
      await t.pumpAndSettle();
      expect(find.text('Google connected.'), findsOneWidget);
      expect(b.writes, 1);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets('connect return with no picture removes the old one', (t) async {
    final b = LinkBridge()
      ..status = 'restored'
      ..google = true
      ..stored = cacheWith(pictureA);
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(imageUrl(pictureA), findsNothing);
    expect(jsonDecode(b.stored).containsKey('picture'), false);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('connect return with a failed overview claims nothing', (
    t,
  ) async {
    final b = LinkBridge()
      ..status = 'restored'
      ..overviewStatus = 500
      ..stored = cacheWith(pictureA);
    await t.pumpWidget(page(b));
    await t.pumpAndSettle();
    expect(find.text('Google connected.'), findsNothing);
    expect(
      find.text('Could not confirm that Google is connected. Check below.'),
      findsOneWidget,
    );
    expect(imageUrl(pictureA), findsNothing);
    expect(b.stored, '');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a pending connect notice bypasses the fresh-cache skip', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final b = LinkBridge()
      ..status = 'restored'
      ..google = true
      ..stored = cacheWith(null);
    await t.pumpWidget(page(b, nav: 'settings'));
    await t.pumpAndSettle();
    expect(b.overviews, 1);
    expect(find.text('Google connected.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('without a notice a fresh cache still skips the overview', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final b = LinkBridge()
      ..status = 'restored'
      ..result = ''
      ..stored = cacheWith(null);
    await t.pumpWidget(page(b, nav: 'settings'));
    await t.pumpAndSettle();
    expect(b.overviews, 0);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('revoke during an in-flight refresh leaves controls usable', (
    t,
  ) async {
    final b = CacheBridge()
      ..status = 'restored'
      ..gate = Completer<void>();
    await t.pumpWidget(page(b));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final old = b.gate!;
    b.gate = null; // later reads answer at once
    b.email = 'second@example.test';
    b.revoke();
    await t.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // The old request finishing late must not restore anything old.
    b.email = 'late@example.test';
    old.complete();
    await t.pumpAndSettle();
    expect(find.text('late@example.test'), findsNothing);
    expect(find.text('second@example.test'), findsWidgets);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
