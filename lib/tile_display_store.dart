import 'tile_display_preference.dart';
import 'tile_display_store_io.dart'
    if (dart.library.js_interop) 'tile_display_store_web.dart'
    as platform;

TileDisplayStore createTileDisplayStore() => platform.createTileDisplayStore();
