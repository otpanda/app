import 'package:material_ui/material_ui.dart';

import 'settings_hub.dart';
import 'tile_display_preference.dart';

/// Device-local settings only. Account logout does not reset these choices.
class DisplaySettings extends StatefulWidget {
  const DisplaySettings({super.key, required this.preference, this.onChanged});
  final TileDisplayPreference preference;
  final VoidCallback? onChanged;
  @override
  State<DisplaySettings> createState() => _DisplaySettingsState();
}

class _DisplaySettingsState extends State<DisplaySettings> {
  bool loading = true, saving = false;
  String? error;
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
      if (mounted)
        setState(() => error = 'Could not save this setting. Try again.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => settingsCard('Account tiles', [
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
  ]);
}
