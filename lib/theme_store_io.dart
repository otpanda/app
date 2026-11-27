import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'theme_choice.dart';

ThemeStore createThemeStore() => _Store();

final class _Store implements ThemeStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}theme-choice-v1');
  }

  @override
  Future<ThemeChoice> read() async {
    final file = await _file();
    if (!await file.exists()) return ThemeChoice.system;
    return ThemeChoice.fromStorage((await file.readAsString()).trim());
  }

  @override
  Future<void> write(ThemeChoice choice) async {
    // Write a temp file and rename it over the real one, so a crash cannot
    // leave a half-written choice. Unknown content reads as System anyway.
    final file = await _file();
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(choice.storageName, flush: true);
    try {
      await temp.rename(file.path);
    } catch (_) {
      try {
        await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
