import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'directory_store.dart';

DirectoryStore? createDirectoryStore() => WebDirectoryStore();

/// localStorage, value `modifiedMs|base64`. A full quota or a blocked
/// storage area throws; the caller treats that as a cache miss.
class WebDirectoryStore implements DirectoryStore {
  static const _prefix = 'otpanda.dir.';

  @override
  Future<Uint8List?> read(String key) async {
    if (!isSafeStoreKey(key)) throw ArgumentError('Unsafe key');
    final v = web.window.localStorage.getItem('$_prefix$key');
    final i = v?.indexOf('|') ?? -1;
    if (v == null || i < 1) return null;
    return base64Decode(v.substring(i + 1));
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    if (!isSafeStoreKey(key)) throw ArgumentError('Unsafe key');
    web.window.localStorage.setItem(
      '$_prefix$key',
      '${DateTime.now().millisecondsSinceEpoch}|${base64Encode(bytes)}',
    );
  }

  @override
  Future<void> delete(String key) async {
    if (!isSafeStoreKey(key)) throw ArgumentError('Unsafe key');
    web.window.localStorage.removeItem('$_prefix$key');
  }

  @override
  Future<List<StoredItem>> list() async {
    final s = web.window.localStorage;
    final out = <StoredItem>[];
    for (var i = 0; i < s.length; i++) {
      final k = s.key(i);
      if (k == null || !k.startsWith(_prefix)) continue;
      final v = s.getItem(k) ?? '';
      final bar = v.indexOf('|');
      if (bar < 1) continue;
      out.add(
        StoredItem(
          k.substring(_prefix.length),
          v.length - bar - 1,
          int.tryParse(v.substring(0, bar)) ?? 0,
        ),
      );
    }
    return out;
  }
}
