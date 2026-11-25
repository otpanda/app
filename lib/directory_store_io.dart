import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'directory_store.dart';

DirectoryStore? createDirectoryStore() => IoDirectoryStore(() async {
  final base = await getApplicationCacheDirectory();
  return Directory('${base.path}${Platform.pathSeparator}service-directory');
});

class IoDirectoryStore implements DirectoryStore {
  final Future<Directory> Function() _dir;
  Directory? _resolved;
  IoDirectoryStore(this._dir);

  Future<Directory> _root() async {
    final d = _resolved ??= await _dir();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _file(String key) async {
    if (!isSafeStoreKey(key)) throw ArgumentError('Unsafe key');
    return File('${(await _root()).path}${Platform.pathSeparator}$key');
  }

  @override
  Future<Uint8List?> read(String key) async {
    final f = await _file(key);
    return await f.exists() ? await f.readAsBytes() : null;
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    final f = await _file(key);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String key) async {
    final f = await _file(key);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<List<StoredItem>> list() async {
    final out = <StoredItem>[];
    await for (final e in (await _root()).list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name.endsWith('.tmp') || !isSafeStoreKey(name)) continue;
      final s = await e.stat();
      out.add(StoredItem(name, s.size, s.modified.millisecondsSinceEpoch));
    }
    return out;
  }
}
