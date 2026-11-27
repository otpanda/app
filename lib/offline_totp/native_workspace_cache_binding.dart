import '../read_workspace_controller.dart';
import 'native_workspace_cache.dart';
import 'native_workspace_snapshot.dart';

/// Binds a successfully unlocked SQLCipher cache to the visible controller.
/// Caller closes this before releasing the unlock lifetime. A failed refresh
/// cannot overwrite healthy cache, and cached capabilities never gain authority.
final class NativeWorkspaceCacheBinding {
  NativeWorkspaceCacheBinding({
    required this.controller,
    required this.cache,
    required this.owner,
    required this.install,
    required this.epoch,
    required this.stillUnlocked,
    required this.clock,
  }) {
    controller.addListener(_published);
  }
  final ReadWorkspaceController controller;
  final NativeWorkspaceCache cache;
  final String owner, install;
  final int epoch;
  final bool Function() stillUnlocked;
  final int Function() clock;
  int _savedRevision = -1;
  bool _closed = false;
  bool saveFailed = false;
  void hydrate() {
    if (_closed || !stillUnlocked()) throw StateError('Workspace locked');
    final saved = cache.read();
    if (saved != null) {
      controller.hydrateUnlocked(
        saved,
        owner: owner,
        install: install,
        epoch: epoch,
      );
    }
  }

  void _published() {
    if (_closed ||
        !stillUnlocked() ||
        !controller.signedIn ||
        controller.loading ||
        !controller.hasLoaded ||
        controller.locallyHydrated ||
        controller.message.isNotEmpty ||
        controller.store.ownerId != owner ||
        controller.publishedRevision == _savedRevision) {
      return;
    }
    final now = clock();
    final snapshot = NativeWorkspaceSnapshot(
      ownerId: owner,
      installId: install,
      epoch: epoch,
      savedAtMs: now,
      entries: controller.store.entries,
      codes: controller.store.visibleCodes(now),
      sources: controller.store.sources,
      unassigned: controller.store.visibleUnassigned(now),
    );
    try {
      cache.save(snapshot);
      _savedRevision = controller.publishedRevision;
      saveFailed = false;
    } catch (_) {
      // Keep the last healthy encrypted snapshot and surface a generic state.
      saveFailed = true;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    controller.removeListener(_published);
  }

  @override
  String toString() => 'NativeWorkspaceCacheBinding(redacted)';
}
