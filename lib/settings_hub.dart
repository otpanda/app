import 'package:material_ui/material_ui.dart';

import 'main.dart' show green, ink, line, muted, pale;

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
  organization(
    'settings/organization',
    'Organization',
    'Tags and pinned entries',
    Icons.sell_outlined,
  );

  final String route;
  final String title, summary;
  final IconData icon;
  const SettingsCategory(this.route, this.title, this.summary, this.icon);
}

const settingsHubRoute = 'settings';

/// Strict parse. Anything not on the allow-list is not a settings route.
SettingsCategory? settingsCategoryForRoute(String? route) {
  for (final c in SettingsCategory.values) {
    if (c.route == route) return c;
  }
  return null;
}

bool isSettingsRoute(String? route) =>
    route == settingsHubRoute || settingsCategoryForRoute(route) != null;

const settingsWideBreakpoint = 700.0;

/// A titled card for one group of settings. Uses the app card theme.
Widget settingsCard(String title, List<Widget> children) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: line),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  ),
);

/// Hub and category pages. Pure layout: it holds no account state, so the
/// owner decides what each page contains and what selecting one does.
/// Wide screens show a category list beside the page. Narrow screens show the
/// list first and each category as its own screen.
class SettingsHub extends StatelessWidget {
  final String? email;
  final SettingsCategory? selected;
  final ValueChanged<SettingsCategory> onSelect;
  final Map<SettingsCategory, Widget> pages;
  const SettingsHub({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.pages,
    this.email,
  });

  List<SettingsCategory> get categories => [
    for (final c in SettingsCategory.values)
      if (pages.containsKey(c)) c,
  ];

  Widget _list(BuildContext context, SettingsCategory? current) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (email != null && current == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              email!,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ),
        for (final c in categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: c == current ? pale : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: c == current ? green : line,
                  width: c == current ? 1.5 : 1,
                ),
              ),
              child: ListTile(
                key: Key('settings-${c.route}'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                leading: Icon(c.icon, color: green),
                title: Text(
                  c.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
                subtitle: Text(c.summary, style: const TextStyle(color: muted)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onSelect(c),
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
        child: ListView(
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
