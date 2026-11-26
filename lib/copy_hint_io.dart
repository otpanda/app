import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'copy_hint.dart';

CopyHintStore createCopyHintStore() => _CopyHint();

class _CopyHint implements CopyHintStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}copy-hint-seen-v1');
  }

  @override
  Future<bool> copiedBefore() async => (await _file()).exists();
  @override
  Future<void> markCopied() async =>
      (await _file()).writeAsString('1', flush: true);
}
