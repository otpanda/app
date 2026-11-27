import 'package:material_ui/material_ui.dart';

import 'theme_controller.dart';

/// Semantic colours. Widgets read these through `context.pal` so light and
/// dark share one set of names. Light values are the original palette.
@immutable
final class OtpPalette extends ThemeExtension<OtpPalette> {
  const OtpPalette({
    required this.ink,
    required this.muted,
    required this.hint,
    required this.line,
    required this.surface,
    required this.card,
    required this.field,
    required this.pale,
    required this.brand,
    required this.onBrand,
    required this.accent,
    required this.arrival,
    required this.arrivalBorder,
    required this.arrivalInk,
    required this.fresh,
    required this.selectedBorder,
    required this.badgeText,
    required this.danger,
    required this.warning,
    required this.banner,
    required this.avatars,
    required this.avatarInk,
    required this.scrim,
    required this.tip,
    required this.tipBorder,
    required this.tipInk,
    required this.notice,
    required this.noticeInk,
    required this.softBorder,
    required this.mutedSoft,
    required this.mutedDeep,
  });

  /// Primary text and headings.
  final Color ink;

  /// Secondary text. Readable, never used for disabled-only text.
  final Color muted;

  /// Placeholder text and quiet icons.
  final Color hint;

  /// Borders and dividers.
  final Color line;

  /// Page background.
  final Color surface;

  /// Cards, tiles, dialogs, app bar.
  final Color card;

  /// Search and text fields.
  final Color field;

  /// Selected row or tile tint.
  final Color pale;

  /// Filled brand surfaces (buttons, avatar, toolbar). White text sits on it.
  final Color brand, onBrand;

  /// Brand colour for icons, strokes, links and focus on surfaces.
  final Color accent;

  /// Arrivals section and fresh code tint, and its border and text.
  final Color arrival, arrivalBorder, arrivalInk, fresh;
  final Color selectedBorder;

  /// Text on the NEW badge, which keeps a bright emerald fill.
  final Color badgeText;
  final Color danger;

  /// Warning panels (preview notices).
  final Color warning;

  /// Tutorial banner fill.
  final Color banner;

  /// Letter-avatar backgrounds and their text.
  final List<Color> avatars;
  final Color avatarInk;

  /// Modal barrier.
  final Color scrim;

  /// Quiet green hint panel, its border and text.
  final Color tip, tipBorder, tipInk;

  /// Amber notice chip and its text.
  final Color notice, noticeInk;

  /// Soft emerald outline for highlighted panels.
  final Color softBorder;

  /// Two secondary-text tones the light design already used: a lighter one
  /// for notes and a deeper one for sign-in help. Dark uses one tone.
  final Color mutedSoft, mutedDeep;

  static const light = OtpPalette(
    ink: Color(0xff12281f),
    muted: Color(0xff5d746a),
    hint: Color(0xff8eaea1),
    line: Color(0xffe0e8e3),
    surface: Color(0xfff4f7f5),
    card: Color(0xffffffff),
    field: Color(0xfff2f5f3),
    pale: Color(0xffe9f8f0),
    brand: Color(0xff0a7955),
    onBrand: Color(0xffffffff),
    accent: Color(0xff0a7955),
    arrival: Color(0xffe1f4ea),
    arrivalBorder: Color(0xff79b99b),
    arrivalInk: Color(0xff123c2e),
    fresh: Color(0xffe6f5ec),
    selectedBorder: Color(0xff0a7955),
    badgeText: Color(0xffffffff),
    danger: Color(0xffb3261e),
    warning: Color(0xfffff6df),
    banner: Color(0xffdff3e8),
    avatars: [
      Color(0xffdff3e8),
      Color(0xffe3ecfb),
      Color(0xfffbe9dc),
      Color(0xffefe5fa),
      Color(0xfffaf0d2),
      Color(0xffdcf1f3),
    ],
    avatarInk: Color(0xff12281f),
    scrim: Color(0x73082c25),
    tip: Color(0xfff2fcf6),
    tipBorder: Color(0xffc5e7d4),
    tipInk: Color(0xff547462),
    notice: Color(0xfffff3d6),
    noticeInk: Color(0xff7a5a12),
    softBorder: Color(0xffb7e6cd),
    mutedSoft: Color(0xff657e70),
    mutedDeep: Color(0xff52665e),
  );

  /// Green-tinted dark neutrals. Elevation is a lighter surface, not a shadow.
  static const dark = OtpPalette(
    ink: Color(0xffe6efe9),
    muted: Color(0xff9db5a8),
    hint: Color(0xff7d9688),
    line: Color(0xff2f3f35),
    surface: Color(0xff0f1613),
    card: Color(0xff1a231f),
    field: Color(0xff222d27),
    pale: Color(0x2210b981),
    brand: Color(0xff0a7955),
    onBrand: Color(0xffffffff),
    accent: Color(0xff34d399),
    arrival: Color(0x1f10b981),
    arrivalBorder: Color(0x4710b981),
    arrivalInk: Color(0xffbdeed7),
    fresh: Color(0x2410b981),
    selectedBorder: Color(0xff34d399),
    badgeText: Color(0xff06231a),
    danger: Color(0xfff2a09b),
    warning: Color(0x33e0a800),
    banner: Color(0x2610b981),
    avatars: [
      Color(0xff1f3a2e),
      Color(0xff1f2f4a),
      Color(0xff44301f),
      Color(0xff33264a),
      Color(0xff443c1b),
      Color(0xff1b3d42),
    ],
    avatarInk: Color(0xffe6efe9),
    scrim: Color(0x8c000000),
    tip: Color(0x1410b981),
    tipBorder: Color(0x3310b981),
    tipInk: Color(0xff9fd4b9),
    notice: Color(0x33e0a800),
    noticeInk: Color(0xfff0cd6e),
    softBorder: Color(0x4010b981),
    mutedSoft: Color(0xff9db5a8),
    mutedDeep: Color(0xff9db5a8),
  );

  @override
  OtpPalette copyWith() => this;

  @override
  OtpPalette lerp(ThemeExtension<OtpPalette>? other, double t) {
    if (other is! OtpPalette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return OtpPalette(
      ink: c(ink, other.ink),
      muted: c(muted, other.muted),
      hint: c(hint, other.hint),
      line: c(line, other.line),
      surface: c(surface, other.surface),
      card: c(card, other.card),
      field: c(field, other.field),
      pale: c(pale, other.pale),
      brand: c(brand, other.brand),
      onBrand: c(onBrand, other.onBrand),
      accent: c(accent, other.accent),
      arrival: c(arrival, other.arrival),
      arrivalBorder: c(arrivalBorder, other.arrivalBorder),
      arrivalInk: c(arrivalInk, other.arrivalInk),
      fresh: c(fresh, other.fresh),
      selectedBorder: c(selectedBorder, other.selectedBorder),
      badgeText: c(badgeText, other.badgeText),
      danger: c(danger, other.danger),
      warning: c(warning, other.warning),
      banner: c(banner, other.banner),
      avatars: [
        for (var i = 0; i < avatars.length; i++)
          c(avatars[i], other.avatars[i]),
      ],
      avatarInk: c(avatarInk, other.avatarInk),
      scrim: c(scrim, other.scrim),
      tip: c(tip, other.tip),
      tipBorder: c(tipBorder, other.tipBorder),
      tipInk: c(tipInk, other.tipInk),
      notice: c(notice, other.notice),
      noticeInk: c(noticeInk, other.noticeInk),
      softBorder: c(softBorder, other.softBorder),
      mutedSoft: c(mutedSoft, other.mutedSoft),
      mutedDeep: c(mutedDeep, other.mutedDeep),
    );
  }

  /// Stable, readable avatar colour so each service keeps one look.
  Color avatarFor(String name) {
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return avatars[h % avatars.length];
  }
}

extension OtpPaletteContext on BuildContext {
  /// The active palette. Hosts without the extension (plain test apps) get
  /// the light palette, which is what they always had.
  OtpPalette get pal =>
      Theme.of(this).extension<OtpPalette>() ?? OtpPalette.light;
}

ThemeData buildOtpandaTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final p = dark ? OtpPalette.dark : OtpPalette.light;
  final seeded = ColorScheme.fromSeed(
    seedColor: OtpPalette.light.brand,
    brightness: brightness,
  );
  final scheme = dark
      ? seeded.copyWith(
          primary: p.accent,
          onPrimary: p.badgeText,
          primaryContainer: p.brand,
          onPrimaryContainer: p.onBrand,
          secondary: p.accent,
          onSecondary: p.badgeText,
          secondaryContainer: const Color(0xff1d3a2f),
          onSecondaryContainer: p.ink,
          surface: p.card,
          onSurface: p.ink,
          onSurfaceVariant: p.muted,
          surfaceContainerLowest: p.surface,
          surfaceContainerLow: p.card,
          surfaceContainer: p.card,
          surfaceContainerHigh: p.field,
          surfaceContainerHighest: p.field,
          outline: const Color(0xff6b8576),
          outlineVariant: p.line,
          error: p.danger,
          onError: const Color(0xff3a0b08),
          scrim: Colors.black,
        )
      : seeded;
  return ThemeData(
    brightness: brightness,
    fontFamily: 'Figtree',
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.surface,
    canvasColor: dark ? p.surface : null,
    dividerColor: dark ? p.line : null,
    dividerTheme: dark ? DividerThemeData(color: p.line) : null,
    extensions: [p],
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontFamily: 'BricolageGrotesque',
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: p.ink,
      ),
      iconTheme: dark ? IconThemeData(color: p.ink) : null,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.card,
      indicatorColor: dark ? const Color(0xff1d3a2f) : p.pale,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ),
    dialogTheme: DialogThemeData(
      constraints: const BoxConstraints(maxWidth: 560),
      titleTextStyle: TextStyle(
        fontFamily: 'BricolageGrotesque',
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        // Filled brand buttons keep the brand green with white text in dark.
        backgroundColor: dark ? p.brand : null,
        foregroundColor: dark ? p.onBrand : null,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: p.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textTheme: TextTheme(bodyMedium: TextStyle(color: p.ink, fontSize: 13)),
    cardTheme: CardThemeData(
      elevation: 0,
      color: p.card,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        side: BorderSide(color: p.line),
      ),
    ),
    popupMenuTheme: dark
        ? PopupMenuThemeData(
            color: p.card,
            surfaceTintColor: Colors.transparent,
          )
        : null,
    bottomSheetTheme: dark
        ? BottomSheetThemeData(
            backgroundColor: p.card,
            surfaceTintColor: Colors.transparent,
          )
        : null,
    snackBarTheme: dark
        ? SnackBarThemeData(
            backgroundColor: const Color(0xffe6efe9),
            contentTextStyle: const TextStyle(color: Color(0xff12281f)),
            actionTextColor: const Color(0xff0a7955),
          )
        : null,
    checkboxTheme: dark
        ? CheckboxThemeData(
            side: const BorderSide(color: Color(0xff4a5f53), width: 2),
            fillColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? p.brand : null,
            ),
            checkColor: WidgetStateProperty.all(p.onBrand),
          )
        : null,
  );
}

/// Rebuilds the app when the appearance choice changes.
class ThemeScope extends StatelessWidget {
  const ThemeScope({
    super.key,
    required this.controller,
    required this.builder,
  });
  final ThemeController controller;
  final Widget Function(
    BuildContext context,
    ThemeData light,
    ThemeData dark,
    ThemeMode mode,
  )
  builder;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => builder(
      context,
      buildOtpandaTheme(Brightness.light),
      buildOtpandaTheme(Brightness.dark),
      controller.mode,
    ),
  );
}
