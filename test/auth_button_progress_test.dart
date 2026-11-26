import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/auth_entry.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/google_button.dart';

class Bridge implements BrowserSessionBridge {
  final wait = Completer<void>();
  int calls = 0;
  @override
  Future<void> passkey() => start('passkey');
  @override
  Future<void> start(String mode) {
    calls++;
    return wait.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

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
  await load('GoogleSans', ['assets/fonts/GoogleSans.ttf']);
  await load('MaterialIcons', [
    '${Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  for (final mode in ['google', 'passkey']) {
    testWidgets(
      '$mode keeps only the clicked button spinning during pending flow',
      (t) async {
        await _fonts();
        final b = Bridge();
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        Widget app({String status = 'signed-out'}) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: otpandaTheme(),
          home: Scaffold(
            body: AuthEntry(
              bridge: b,
              status: status,
              message: '',
              busy: false,
              run: (f) => f(),
            ),
          ),
        );
        await t.pumpWidget(app());
        await t.pumpAndSettle();
        await t.tap(
          mode == 'google'
              ? find.byType(GoogleSignInButton)
              : find.text('Sign in with a passkey'),
        );
        await t.pump();
        await t.pump(const Duration(milliseconds: 500));
        // Repeat tap cannot launch another authentication operation.
        await t.tap(
          mode == 'google'
              ? find.byType(GoogleSignInButton)
              : find.text('Sign in with a passkey'),
        );
        await t.pump();
        expect(b.calls, 1);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        final google = t.widget<GoogleSignInButton>(
          find.byType(GoogleSignInButton),
        );
        expect(google.onPressed, isNull);
        expect(google.loading, mode == 'google');
        final passkey = find.widgetWithText(
          OutlinedButton,
          'Sign in with a passkey',
        );
        expect(t.widget<OutlinedButton>(passkey).onPressed, isNull);
        await t.pumpWidget(app(status: 'authenticating'));
        await t.pump();
        expect(find.byType(GoogleSignInButton), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        // Readable golden rasterization is Linux-specific; functional state
        // assertions above run unchanged on every supported desktop platform.
        if (Platform.isLinux) {
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/auth_pending_$mode.png'),
          );
        }
        b.wait.complete();
        await t.pump();
        await t.pumpWidget(app());
        await t.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final outcome in ['cancel', 'error']) {
    testWidgets('signup-ready inline loading clears on $outcome', (t) async {
      final b = Bridge();
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: Scaffold(
            body: AuthEntry(
              bridge: b,
              status: 'signup-ready',
              message: '',
              busy: false,
              run: (f) async {
                try {
                  await f();
                } catch (_) {}
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Create my passkey'));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await t.tap(find.text('Create my passkey'));
      await t.pump();
      expect(b.calls, 1);
      if (outcome == 'error') {
        b.wait.completeError(StateError('fixture'));
      } else {
        b.wait.complete();
      }
      await t.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create my passkey'),
            )
            .onPressed,
        isNotNull,
      );
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
}
