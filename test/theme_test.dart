import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/app_theme.dart';
import 'package:otpanda_client/display_settings.dart';
import 'package:otpanda_client/main.dart' as legacy;
import 'package:otpanda_client/theme_choice.dart';
import 'package:otpanda_client/theme_controller.dart';
import 'package:otpanda_client/tile_display_preference.dart';

class MemTheme implements ThemeStore {
  ThemeChoice? saved;
  bool failRead = false, failWrite = false;
  Object? raw;
  @override
  Future<ThemeChoice> read() async {
    if (failRead) throw StateError('unreadable');
    return saved ?? ThemeChoice.system;
  }

  @override
  Future<void> write(ThemeChoice choice) async {
    if (failWrite) throw StateError('unwritable');
    saved = choice;
  }
}

/// A store whose read completes only when the test says so.
class SlowTheme extends MemTheme {
  final gate = Completer<ThemeChoice>();
  @override
  Future<ThemeChoice> read() => gate.future;
}

class MemTiles implements TileDisplayStore {
  bool v = false;
  @override
  Future<bool> showTags() async => v;
  @override
  Future<void> setShowTags(bool e) async => v = e;
}

double luminance(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// Contrast of [fg] over [bg]. A translucent fg is composited over [bg] first.
double contrast(Color fg, Color bg) {
  final f = Color.alphaBlend(fg, bg);
  final a = luminance(f), b = luminance(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

void main() {
  group('choice and controller', () {
    test('unknown or missing stored values mean System', () {
      expect(ThemeChoice.fromStorage(null), ThemeChoice.system);
      expect(ThemeChoice.fromStorage('purple'), ThemeChoice.system);
      expect(ThemeChoice.fromStorage(''), ThemeChoice.system);
      for (final c in ThemeChoice.values) {
        expect(ThemeChoice.fromStorage(c.storageName), c);
      }
    });
    test('defaults to System and follows the platform', () async {
      final c = ThemeController(MemTheme());
      expect(c.choice, ThemeChoice.system);
      expect(c.mode, ThemeMode.system);
      await c.load();
      expect(c.choice, ThemeChoice.system);
    });
    test('saves, then restores on the next start', () async {
      final store = MemTheme();
      final a = ThemeController(store);
      var notified = 0;
      a.addListener(() => notified++);
      await a.set(ThemeChoice.dark);
      expect(a.mode, ThemeMode.dark);
      expect(notified, 1);
      final b = ThemeController(store);
      await b.load();
      expect(b.choice, ThemeChoice.dark);
      await a.set(ThemeChoice.light);
      expect(a.mode, ThemeMode.light);
    });
    test(
      'a failed save keeps the old choice and reports the failure',
      () async {
        final store = MemTheme();
        final c = ThemeController(store);
        await c.set(ThemeChoice.dark);
        store.failWrite = true;
        await expectLater(c.set(ThemeChoice.light), throwsStateError);
        expect(c.choice, ThemeChoice.dark);
        expect(store.saved, ThemeChoice.dark);
      },
    );
    test('an unreadable store starts as System, never throws', () async {
      final store = MemTheme()..failRead = true;
      final c = ThemeController(store);
      await c.load();
      expect(c.choice, ThemeChoice.system);
    });
    test('rapid choices persist in tap order', () async {
      final store = MemTheme();
      final c = ThemeController(store);
      final fs = [
        c.set(ThemeChoice.dark),
        c.set(ThemeChoice.light),
        c.set(ThemeChoice.system),
      ];
      await Future.wait(fs);
      expect(c.choice, ThemeChoice.system);
      expect(store.saved, ThemeChoice.system);
    });
    test(
      'slow read of Dark, then a FAILED save: the stored Dark still applies',
      () async {
        final store = SlowTheme()..failWrite = true;
        final c = ThemeController(store);
        final load = c.load();
        await expectLater(c.set(ThemeChoice.light), throwsStateError);
        store.gate.complete(ThemeChoice.dark);
        await load;
        expect(c.choice, ThemeChoice.dark);
      },
    );
    test('slow read, then a successful save: the save wins', () async {
      final store = SlowTheme();
      final c = ThemeController(store);
      final load = c.load();
      await c.set(ThemeChoice.light);
      store.gate.complete(ThemeChoice.dark);
      await load;
      expect(c.choice, ThemeChoice.light);
      expect(store.saved, ThemeChoice.light);
    });
    test('a store that never answers cannot block startup', () async {
      final store = SlowTheme();
      final c = ThemeController(store);
      final sw = Stopwatch()..start();
      await c.loadBounded(const Duration(milliseconds: 50));
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(c.choice, ThemeChoice.system);
      // The read finally returns: it applies, nothing was saved meanwhile.
      var notified = 0;
      c.addListener(() => notified++);
      store.gate.complete(ThemeChoice.dark);
      await Future<void>.delayed(Duration.zero);
      expect(c.choice, ThemeChoice.dark);
      expect(notified, 1);
    });
    test('a late read after a successful save is ignored', () async {
      final store = SlowTheme();
      final c = ThemeController(store);
      await c.loadBounded(const Duration(milliseconds: 10));
      await c.set(ThemeChoice.light);
      store.gate.complete(ThemeChoice.dark);
      await Future<void>.delayed(Duration.zero);
      expect(c.choice, ThemeChoice.light);
    });
    test('a throwing read after the timeout stays System', () async {
      final store = SlowTheme();
      final c = ThemeController(store);
      await c.loadBounded(const Duration(milliseconds: 10));
      store.gate.completeError(StateError('boom'));
      await Future<void>.delayed(Duration.zero);
      expect(c.choice, ThemeChoice.system);
    });
    test('logout and sign-in code never clear device-wide storage', () {
      // The choice lives beside the tile-tags choice and must survive both.
      final files = [
        ...Directory('lib').listSync(recursive: true).whereType<File>(),
        File('tool/session-bootstrap.js'),
      ].where((f) => f.path.endsWith('.dart') || f.path.endsWith('.js'));
      for (final f in files) {
        final text = f.readAsStringSync();
        expect(text.contains('localStorage.clear'), isFalse, reason: f.path);
        expect(text.contains('sessionStorage.clear'), isFalse, reason: f.path);
        expect(
          RegExp(r'getApplicationSupportDirectory\(\)[\s\S]{0,80}delete')
              .hasMatch(text),
          isFalse,
          reason: f.path,
        );
      }
    });

    test('a late load never overrides a choice made meanwhile', () async {
      final store = MemTheme()..saved = ThemeChoice.light;
      final c = ThemeController(store);
      final load = c.load();
      await c.set(ThemeChoice.dark);
      await load;
      expect(c.choice, ThemeChoice.dark);
    });
  });

  group('palette', () {
    test('light palette is the original palette', () {
      const p = OtpPalette.light;
      expect(p.ink, legacy.ink);
      expect(p.muted, legacy.muted);
      expect(p.line, legacy.line);
      expect(p.pale, legacy.pale);
      expect(p.surface, legacy.surface);
      expect(p.brand, legacy.green);
      expect(p.card, Colors.white);
    });
    test('light theme keeps its original look', () {
      final t = buildOtpandaTheme(Brightness.light);
      expect(t.scaffoldBackgroundColor, legacy.surface);
      expect(t.cardTheme.color, Colors.white);
      expect(t.dialogTheme.backgroundColor, Colors.white);
      expect(t.brightness, Brightness.light);
    });
    for (final entry in {
      'light': OtpPalette.light,
      'dark': OtpPalette.dark,
    }.entries) {
      final p = entry.value;
      test('${entry.key}: readable text on every surface', () {
        for (final bg in [p.surface, p.card, p.field]) {
          expect(contrast(p.ink, bg), greaterThan(7), reason: 'ink on $bg');
          expect(contrast(p.muted, bg), greaterThan(4.5), reason: 'muted $bg');
          expect(contrast(p.accent, bg), greaterThan(4.5), reason: 'accent');
        }
        // Tinted panels sit on the card.
        for (final tint in [p.pale, p.arrival, p.tip, p.fresh, p.banner]) {
          final bg = Color.alphaBlend(tint, p.card);
          expect(contrast(p.ink, bg), greaterThan(7), reason: 'ink on tint');
          // The original light muted text is a little under AA on tints.
          // Only the new dark palette is held to AA there.
          expect(
            contrast(p.muted, bg),
            greaterThan(p == OtpPalette.dark ? 4.5 : 4.0),
            reason: 'muted tint',
          );
          expect(
            contrast(p.accent, bg),
            greaterThan(4.5),
            reason: 'accent tint',
          );
        }
        expect(contrast(p.onBrand, p.brand), greaterThan(4.5));
        expect(contrast(p.danger, p.card), greaterThan(4.5));
        expect(
          contrast(p.noticeInk, Color.alphaBlend(p.notice, p.card)),
          greaterThan(4.5),
        );
        expect(
          contrast(p.tipInk, Color.alphaBlend(p.tip, p.card)),
          greaterThan(4.5),
        );
        for (final a in p.avatars) {
          expect(contrast(p.avatarInk, a), greaterThan(7));
        }
        expect(p.avatars.length, 6);
      });
      test('${entry.key}: borders are visible but quiet', () {
        expect(contrast(p.line, p.card), greaterThan(1.1));
      });
    }
    test('dark surfaces are dark and elevation is lighter, not shadow', () {
      const p = OtpPalette.dark;
      expect(luminance(p.surface), lessThan(luminance(p.card)));
      expect(luminance(p.card), lessThan(luminance(p.field)));
      expect(luminance(p.card), lessThan(0.05));
    });
    test('badge text stays readable on the emerald NEW badge in dark', () {
      expect(
        contrast(OtpPalette.dark.badgeText, const Color(0xff10b981)),
        greaterThan(4.5),
      );
    });
    test('avatars: same service keeps the same colour', () {
      expect(
        OtpPalette.dark.avatarFor('GitHub'),
        OtpPalette.dark.avatarFor('GitHub'),
      );
      expect(
        OtpPalette.light.avatars.indexOf(OtpPalette.light.avatarFor('GitHub')),
        OtpPalette.dark.avatars.indexOf(OtpPalette.dark.avatarFor('GitHub')),
      );
    });
    test('dark theme paints the app, dialogs and fields dark', () {
      final t = buildOtpandaTheme(Brightness.dark);
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, OtpPalette.dark.surface);
      expect(t.cardTheme.color, OtpPalette.dark.card);
      expect(t.dialogTheme.backgroundColor, OtpPalette.dark.card);
      expect(t.appBarTheme.backgroundColor, OtpPalette.dark.card);
      expect(t.colorScheme.onSurface, OtpPalette.dark.ink);
      expect(t.extension<OtpPalette>(), OtpPalette.dark);
    });
    test('plain hosts without the extension get the light palette', () {
      expect(
        OtpPalette.light.lerp(OtpPalette.dark, 0).ink,
        OtpPalette.light.ink,
      );
      expect(
        OtpPalette.light.lerp(OtpPalette.dark, 1).card,
        OtpPalette.dark.card,
      );
    });
  });

  group('app follows the choice', () {
    Future<void> pump(WidgetTester t, ThemeController c, Brightness os) async {
      t.platformDispatcher.platformBrightnessTestValue = os;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      await t.pumpWidget(
        ThemeScope(
          controller: c,
          builder: (context, light, dark, mode) => MaterialApp(
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            home: Builder(
              builder: (context) => Scaffold(
                body: Text('x', key: Key('b-${context.pal.card.toARGB32()}')),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('System follows the OS, both ways', (t) async {
      final c = ThemeController(MemTheme());
      await pump(t, c, Brightness.dark);
      expect(
        find.byKey(Key('b-${OtpPalette.dark.card.toARGB32()}')),
        findsOneWidget,
      );
      await pump(t, c, Brightness.light);
      await t.pumpAndSettle();
      expect(
        find.byKey(Key('b-${OtpPalette.light.card.toARGB32()}')),
        findsOneWidget,
      );
    });
    testWidgets('Light and Dark ignore the OS and switch live', (t) async {
      final c = ThemeController(MemTheme());
      await pump(t, c, Brightness.dark);
      await c.set(ThemeChoice.light);
      await t.pumpAndSettle();
      expect(
        find.byKey(Key('b-${OtpPalette.light.card.toARGB32()}')),
        findsOneWidget,
      );
      await pump(t, c, Brightness.light);
      await c.set(ThemeChoice.dark);
      await t.pumpAndSettle();
      expect(
        find.byKey(Key('b-${OtpPalette.dark.card.toARGB32()}')),
        findsOneWidget,
      );
    });
  });

  group('Display settings', () {
    Future<void> show(WidgetTester t, ThemeController c) async {
      await t.pumpWidget(
        ThemeScope(
          controller: c,
          builder: (context, light, dark, mode) => MaterialApp(
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            home: Scaffold(
              body: SingleChildScrollView(
                child: DisplaySettings(
                  preference: TileDisplayPreference(MemTiles()),
                  theme: c,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    testWidgets('System is selected by default', (t) async {
      final c = ThemeController(MemTheme());
      await show(t, c);
      final b = t.widget<SegmentedButton<ThemeChoice>>(
        find.byKey(const Key('theme-choice')),
      );
      expect(b.selected, {ThemeChoice.system});
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
    });
    testWidgets('choosing Dark saves and repaints', (t) async {
      final store = MemTheme();
      final c = ThemeController(store);
      await show(t, c);
      await t.tap(find.text('Dark'));
      await t.pumpAndSettle();
      expect(store.saved, ThemeChoice.dark);
      expect(c.mode, ThemeMode.dark);
      expect(
        Theme.of(t.element(find.byKey(const Key('theme-choice')))).brightness,
        Brightness.dark,
      );
      expect(
        t
            .widget<SegmentedButton<ThemeChoice>>(
              find.byKey(const Key('theme-choice')),
            )
            .selected,
        {ThemeChoice.dark},
      );
    });
    testWidgets('a failed save keeps the old choice and says so', (t) async {
      final store = MemTheme()..failWrite = true;
      final c = ThemeController(store);
      await show(t, c);
      await t.tap(find.text('Dark'));
      await t.pumpAndSettle();
      expect(c.choice, ThemeChoice.system);
      expect(find.byKey(const Key('theme-save-error')), findsOneWidget);
      expect(
        t
            .widget<SegmentedButton<ThemeChoice>>(
              find.byKey(const Key('theme-choice')),
            )
            .selected,
        {ThemeChoice.system},
      );
    });
    testWidgets('keeps the tile tags switch', (t) async {
      await show(t, ThemeController(MemTheme()));
      expect(find.byKey(const Key('show-tile-tags')), findsOneWidget);
    });
  });
}
