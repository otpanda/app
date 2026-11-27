import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'tile_display_preference.dart';

TileDisplayStore createTileDisplayStore() => _Store();

/// Device-local, non-secret display preference. Never cleared by account logout.
final class _Store implements TileDisplayStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}show-tile-tags-v1');
  }

  @override
  Future<bool> showTags() async {
    final file = await _file();
    if (!await file.exists()) return false;
    return (await file.readAsString()) == '1';
  }

  @override
  Future<void> setShowTags(bool enabled) async {
    await (await _file()).writeAsString(enabled ? '1' : '0', flush: true);
  }
}
