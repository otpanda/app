import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'settings_hub.dart';
import 'theme_choice.dart';
import 'theme_controller.dart';
import 'tile_display_preference.dart';

/// Device-local settings only. Account logout does not reset these choices.
class DisplaySettings extends StatefulWidget {
  const DisplaySettings({
    super.key,
    required this.preference,
    this.onChanged,
    this.theme,
  });
  final TileDisplayPreference preference;

  /// Appearance choice. Defaults to the app-wide controller.
  final ThemeController? theme;
  final VoidCallback? onChanged;
  @override
  State<DisplaySettings> createState() => _DisplaySettingsState();
}

class _DisplaySettingsState extends State<DisplaySettings> {
  bool loading = true, saving = false;
  String? error, themeError;
  ThemeController get theme => widget.theme ?? appThemeController;

  Future<void> changeTheme(ThemeChoice choice) async {
    setState(() => themeError = null);
    try {
      await theme.set(choice);
    } catch (_) {
      if (mounted) {
        setState(() => themeError = 'Could not save the theme. Try again.');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.preference.load().then((_) {
      if (mounted) setState(() => loading = false);
    });
  }

  Future<void> change(bool enabled) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.preference.setShowTags(enabled);
      widget.onChanged?.call();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not save this setting. Try again.');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      settingsCard('Theme', [
        ListenableBuilder(
          listenable: theme,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<ThemeChoice>(
                key: const Key('theme-choice'),
                showSelectedIcon: false,
                segments: [
                  for (final c in ThemeChoice.values)
                    ButtonSegment(
                      value: c,
                      label: Text(c.label),
                      icon: Icon(switch (c) {
                        ThemeChoice.system => Icons.brightness_auto_outlined,
                        ThemeChoice.light => Icons.light_mode_outlined,
                        ThemeChoice.dark => Icons.dark_mode_outlined,
                      }),
                    ),
                ],
                selected: {theme.choice},
                onSelectionChanged: (s) => changeTheme(s.first),
              ),
              const SizedBox(height: 8),
              Text(
                'System follows your device setting. Only on this device.',
                style: TextStyle(color: context.pal.muted),
              ),
              if (themeError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: Text(
                    themeError!,
                    key: const Key('theme-save-error'),
                    style: TextStyle(color: context.pal.danger),
                  ),
                ),
            ],
          ),
        ),
      ]),
      settingsCard('Account tiles', [
        SwitchListTile(
          key: const Key('show-tile-tags'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Show tags on account tiles'),
          subtitle: const Text(
            'Adds a full-width tag row below each account. Accounts without tags show Add tags. Only on this device.',
          ),
          value: widget.preference.showTags,
          onChanged: loading || saving ? null : change,
        ),
        if (loading || saving) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, key: const Key('display-save-error')),
          ),
      ]),
    ],
  );
}
