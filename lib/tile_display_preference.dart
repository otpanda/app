import 'dart:async';

/// Non-secret per-device display preference. Never synced with account data.
abstract interface class TileDisplayStore {
  Future<bool> showTags();
  Future<void> setShowTags(bool enabled);
}

/// Default is compact. A failed write never claims the preference was saved.
/// Saves serialize so rapid toggles cannot persist in the wrong order.
final class TileDisplayPreference {
  TileDisplayPreference(this.store);
  final TileDisplayStore store;
  bool _showTags = false;
  bool get showTags => _showTags;
  Future<void> _tail = Future.value();
  int _revision = 0;

  Future<void> load() async {
    final revision = _revision;
    bool saved;
    try {
      saved = await store.showTags();
    } catch (_) {
      saved = false;
    }
    if (_revision == revision) _showTags = saved;
  }

  Future<void> setShowTags(bool enabled) {
    _revision++;
    final result = _tail.then((_) async {
      await store.setShowTags(enabled);
      _showTags = enabled;
    });
    _tail = result.catchError((Object _) {});
    return result;
  }
}
