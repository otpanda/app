import 'package:web/web.dart' as web;

import 'tile_display_preference.dart';

TileDisplayStore createTileDisplayStore() => _Store();

final class _Store implements TileDisplayStore {
  static const _key = 'otpanda.show-tile-tags.v1';
  @override
  Future<bool> showTags() async => web.window.localStorage.getItem(_key) == '1';
  @override
  Future<void> setShowTags(bool enabled) async =>
      web.window.localStorage.setItem(_key, enabled ? '1' : '0');
}
