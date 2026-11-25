import 'dart:typed_data';

import 'directory_store_io.dart'
    if (dart.library.js_interop) 'directory_store_web.dart'
    as impl;

class StoredItem {
  final String key;
  final int size;
  final int modifiedMs;
  const StoredItem(this.key, this.size, this.modifiedMs);
}

/// Small key/byte store behind the service directory cache. Keys are checked
/// by [isSafeStoreKey] before they reach a file name or storage key. Every
/// method may fail; the callers treat a failure as a cache miss.
abstract interface class DirectoryStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List bytes);
  Future<void> delete(String key);
  Future<List<StoredItem>> list();
}

final _safeKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,150}$');
bool isSafeStoreKey(String key) =>
    _safeKey.hasMatch(key) && !key.contains('..');

/// Platform store: files in the app cache directory on native, localStorage on
/// the web. Null when the platform has none, which leaves memory-only caching.
DirectoryStore? createDirectoryStore() => impl.createDirectoryStore();
