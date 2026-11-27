import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

import 'profile_header.dart';

/// The settings categories and the route ids primary's router allow-lists.
enum SettingsCategory {
  account(
    'settings/account-security',
    'Account & security',
    'Sign-in methods, passkeys, recovery',
    Icons.shield_outlined,
  ),
  devices(
    'settings/devices',
    'Devices & sessions',
    'Where you are signed in',
    Icons.devices_outlined,
  ),
  sources(
    'settings/sources',
    'Sources',
    'Mailboxes and phones that receive codes',
    Icons.inbox_outlined,
  ),
  display(
    'settings/display',
    'Display',
    'Account tile appearance on this device',
    Icons.view_compact_outlined,
  ),
  about(
    'settings/about',
    'About',
    'Version, links, licenses',
    Icons.info_outline,
  );

  final String route;
  final String title, summary;
  final IconData icon;
  const SettingsCategory(this.route, this.title, this.summary, this.icon);
}

const settingsHubRoute = 'settings';

/// A page under Account & security. Allow-listed with the categories.
const settingsPasskeysRoute = 'settings/account-security/passkeys';

/// Strict parse. Anything not on the allow-list is not a settings route.
SettingsCategory? settingsCategoryForRoute(String? route) {
  for (final c in SettingsCategory.values) {
    if (c.route == route) return c;
  }
  return null;
}

bool isSettingsRoute(String? route) =>
    route == settingsHubRoute ||
    route == settingsPasskeysRoute ||
    settingsCategoryForRoute(route) != null;

const settingsWideBreakpoint = 700.0;

/// Confirmation dialogs in settings stay compact on wide screens instead of
/// stretching to the viewport. Narrow screens are unaffected (the dialog is
/// already narrower than this).
const settingsDialogConstraints = BoxConstraints(maxWidth: 400);

/// Stands in for text that has not loaded. It lays out a sample of the real
/// text, so it wraps and takes the same height the loaded text will, and
/// paints it as grey bars instead of letters. Nothing is hard-coded: the
/// height follows the sample's content and the screen width.
class RedactedText extends StatelessWidget {
  final String sample;
  final double? fontSize;
  const RedactedText(this.sample, {super.key, this.fontSize});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Text(
      sample,
      style: TextStyle(
        color: Colors.transparent,
        backgroundColor: context.pal.line,
        fontSize: fontSize,
      ),
    ),
  );
}

/// Text that keeps the height of the tallest of its possible versions. Each
/// version is laid out invisibly under the one shown (or its redacted
/// stand-in while loading), so a setting that changes its wording between
/// states does not change its row's height. Content-driven: the height is
/// whatever the longest wording needs at the current width.
class StableText extends StatelessWidget {
  final String? shown;
  final List<String> versions;
  final double? fontSize;
  const StableText({
    super.key,
    required this.shown,
    required this.versions,
    this.fontSize,
  });
  @override
  Widget build(BuildContext context) {
    final style = fontSize == null ? null : TextStyle(fontSize: fontSize);
    return Stack(
      children: [
        for (final v in versions)
          ExcludeSemantics(
            child: Opacity(opacity: 0, child: Text(v, style: style)),
          ),
        if (shown == null)
          RedactedText(versions.first, fontSize: fontSize)
        else
          Text(shown!, style: style),
      ],
    );
  }
}

/// A titled card for one group of settings. Uses the app card theme.
Widget settingsCard(String title, List<Widget> children) => Builder(
  builder: (context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.pal.ink,
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: context.pal.line),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    ),
  ),
);

/// Hub and category pages. Pure layout: it holds no account state, so the
/// owner decides what each page contains and what selecting one does.
/// Wide screens show a category list beside the page. Narrow screens show the
/// list first and each category as its own screen.
class SettingsHub extends StatelessWidget {
  final String? email, googlePicture;

  /// The account has not loaded yet: the header holds its space meanwhile.
  final bool emailLoading;
  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelect;
  final Map<SettingsCategory, Widget> pages;

  /// Shown at the bottom of the category list (Sign out).
  final Widget? footer;

  /// Pages that lay themselves out to the full height of the screen instead
  /// of scrolling as a whole (they scroll an inner list and pin a footer).
  final Set<SettingsCategory> fillPages;
  const SettingsHub({
    this.fillPages = const {},
    this.footer,
    super.key,
    required this.selected,
    required this.onSelect,
    required this.pages,
    this.email,
    this.googlePicture,
    this.emailLoading = false,
  });

  List<SettingsCategory> get categories => [
    for (final c in SettingsCategory.values)
      if (pages.containsKey(c)) c,
  ];

  Widget _list(BuildContext context, SettingsCategory? current) {
    final top = <Widget>[
      if (email != null || emailLoading)
        ProfileHeader(email: email, googlePicture: googlePicture),
      for (final c in categories)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: c == current ? context.pal.pale : context.pal.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: c == current
                    ? context.pal.selectedBorder
                    : context.pal.line,
                width: c == current ? 1.5 : 1,
              ),
            ),
            child: ListTile(
              key: Key('settings-${c.route}'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              leading: Icon(c.icon, color: context.pal.accent),
              title: Text(
                c.title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: context.pal.ink,
                ),
              ),
              subtitle: Text(
                c.summary,
                style: TextStyle(color: context.pal.muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onSelect(c),
            ),
          ),
        ),
    ];
    // The list scrolls when it is taller than the screen. When it is shorter,
    // Licenses and Sign out sit at the very bottom of the screen.
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          sliver: SliverList(delegate: SliverChildListDelegate(top)),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [?footer],
            ),
          ),
        ),
      ],
    );
  }

  Widget _page(BuildContext context, SettingsCategory c) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: fillPages.contains(c)
            ? Padding(
                key: ValueKey(c.route),
                padding: const EdgeInsets.all(16),
                child: pages[c]!,
              )
            : ListView(
                key: ValueKey(c.route),
                padding: const EdgeInsets.all(16),
                children: [pages[c]!],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth > settingsWideBreakpoint;
        final cats = categories;
        final current = pages.containsKey(selected) ? selected : null;
        if (wide) {
          final shown = current ?? (cats.isEmpty ? null : cats.first);
          return Row(
            children: [
              SizedBox(width: 320, child: _list(context, shown)),
              const VerticalDivider(width: 1),
              Expanded(
                child: shown == null
                    ? const SizedBox.shrink()
                    : _page(context, shown),
              ),
            ],
          );
        }
        if (current == null) {
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: _list(context, null),
            ),
          );
        }
        return _page(context, current);
      },
    );
  }
}
