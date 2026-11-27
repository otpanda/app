import 'package:material_ui/material_ui.dart';

import 'theme_choice.dart';
import 'theme_store.dart';

/// Holds the appearance choice for the whole app. Listeners rebuild when it
/// changes. A failed save never claims the choice was kept: the in-memory
/// choice and the saved one stay equal. Saves are serialized so quick taps
/// cannot persist in the wrong order. Storage is per device, and on the web
/// per origin and browser profile, with no cross-tab notification: another
/// open tab picks the choice up on its next start.
final class ThemeController extends ChangeNotifier {
  ThemeController(this.store);
  final ThemeStore store;
  ThemeChoice _choice = ThemeChoice.system;
  ThemeChoice get choice => _choice;
  ThemeMode get mode => switch (_choice) {
    ThemeChoice.system => ThemeMode.system,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.dark => ThemeMode.dark,
  };
  Future<void> _tail = Future.value();

  /// Counts successful writes only. A load result applies unless a write has
  /// succeeded since the load began, so a slow read of a stored choice is not
  /// thrown away because a later save failed (which would strand System).
  int _writes = 0;

  /// A failed read falls back to System and never throws.
  Future<void> load() async {
    final writesAtStart = _writes;
    ThemeChoice saved;
    try {
      saved = await store.read();
    } catch (_) {
      saved = ThemeChoice.system;
    }
    if (_writes == writesAtStart && saved != _choice) {
      _choice = saved;
      notifyListeners();
    }
  }

  /// Startup helper: waits at most [limit] for the stored choice, then lets
  /// the app start on System. A late read still applies when it completes and
  /// no save has succeeded meanwhile. Never throws.
  Future<void> loadBounded([Duration limit = const Duration(seconds: 2)]) =>
      load().timeout(limit, onTimeout: () {});

  Future<void> set(ThemeChoice choice) {
    final result = _tail.then((_) async {
      await store.write(choice);
      _writes++;
      if (_choice != choice) {
        _choice = choice;
        notifyListeners();
      }
    });
    _tail = result.catchError((Object _) {});
    return result;
  }
}

/// The app-wide controller. Tests and hosts may pass their own.
final ThemeController appThemeController = ThemeController(createThemeStore());
