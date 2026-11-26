import 'package:web/web.dart' as web;

import 'copy_hint.dart';

CopyHintStore createCopyHintStore() => _CopyHint();

class _CopyHint implements CopyHintStore {
  static const _key = 'otpanda.copy-hint-seen.v1';
  @override
  Future<bool> copiedBefore() async =>
      web.window.localStorage.getItem(_key) == '1';
  @override
  Future<void> markCopied() async => web.window.localStorage.setItem(_key, '1');
}
