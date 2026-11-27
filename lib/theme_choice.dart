import 'dart:async';

/// The device-local appearance choice. System follows the operating system.
enum ThemeChoice {
  system('system', 'System'),
  light('light', 'Light'),
  dark('dark', 'Dark');

  const ThemeChoice(this.storageName, this.label);
  final String storageName;
  final String label;

  /// Unknown or missing stored values mean System, never an error.
  static ThemeChoice fromStorage(String? value) {
    for (final c in values) {
      if (c.storageName == value) return c;
    }
    return ThemeChoice.system;
  }
}

/// Non-secret per-device appearance store. Never synced, never cleared by
/// account logout or switching accounts.
abstract interface class ThemeStore {
  Future<ThemeChoice> read();
  Future<void> write(ThemeChoice choice);
}
