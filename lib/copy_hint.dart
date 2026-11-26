import 'copy_hint_io.dart'
    if (dart.library.js_interop) 'copy_hint_web.dart'
    as platform;

/// Non-secret installation preference, never code/account/clipboard data.
abstract interface class CopyHintStore {
  Future<bool> copiedBefore();
  Future<void> markCopied();
}

CopyHintStore createCopyHintStore() => platform.createCopyHintStore();
