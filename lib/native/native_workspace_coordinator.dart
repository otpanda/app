import 'dart:async';

import 'package:flutter/foundation.dart';

import '../offline_totp/native_offline_workspace_runtime.dart';
import '../offline_totp/native_seed_custody.dart';
import '../offline_totp/native_workspace_snapshot.dart';
import '../offline_totp/secret_store.dart';
import '../read_workspace_controller.dart';
import 'native_workspace_admission.dart';

/// Binds authenticated snapshots and independent cold local admission. Every
/// await is fenced by the local-unlock generation; no session is manufactured.
class NativeWorkspaceCoordinator extends ChangeNotifier {
  NativeWorkspaceCoordinator({
    required this.admission,
    required this.custody,
    required this.keys,
    required this.runtime,
    required this.locallyUnlocked,
  });
  final NativeWorkspaceAdmission admission;
  final NativeSeedCustody custody;
  final SecretStore keys;
  final NativeOfflineWorkspaceRuntime runtime;
  final bool Function() locallyUnlocked;
  NativeWorkspaceScope? scope;
  bool unavailable = false;
  bool _disposed = false, _opening = false;
  int _generation = 0;
  ReadWorkspaceController? _controller;
  int _savedRevision = -1;
  String? _admittedOwner;
  Future<void> _operations = Future.value();
  Future<void> _serial(Future<void> Function() action) {
    final next = _operations.catchError((_) {}).then((_) => action());
    _operations = next;
    return next;
  }

  bool get hasLocalView => scope != null && runtime.snapshot != null;
  bool active(int generation) =>
      !_disposed && generation == _generation && locallyUnlocked();

  Future<void> discover() {
    final generation = _generation;
    return _serial(() => _discover(generation));
  }

  Future<void> _discover(int generation) async {
    if (_opening || !active(generation)) return;
    _opening = true;
    try {
      final found = await admission.discover();
      if (!active(generation) || found == null) return;
      await _open(found, false, generation);
    } catch (_) {
      if (active(generation)) {
        unavailable = true;
        notifyListeners();
      }
    } finally {
      _opening = false;
    }
  }

  Future<void> _open(
    NativeWorkspaceScope found,
    bool create,
    int generation,
  ) async {
    if (!active(generation)) return;
    await runtime.open(
      keys: keys,
      custody: custody,
      namespace: found.namespace,
      path: found.path,
      owner: found.owner,
      install: found.install,
      epoch: found.epoch,
      admittedFreshWorkspace: create,
      stillLocallyUnlocked: () => active(generation),
    );
    if (!active(generation)) return;
    if (runtime.phase != NativeOfflineWorkspacePhase.ready) {
      throw StateError('Workspace unavailable');
    }
    scope = found;
    _admittedOwner = found.owner;
    unavailable = false;
    notifyListeners();
  }

  /// Caller has verified this owner from a fresh authenticated session response.
  /// This never enables custody or enrolls a device implicitly.
  Future<void> admitAuthenticated(String owner) {
    final generation = _generation;
    return _serial(() => _admitAuthenticated(owner, generation));
  }

  Future<void> _admitAuthenticated(String owner, int generation) async {
    if (!active(generation)) return;
    try {
      final state = await custody.readOwnerState(owner);
      if (!active(generation) || !state.enabled) return;
      _admittedOwner = owner;
      final admitted = await admission.admit(owner, state.epoch);
      if (!active(generation)) return;
      if (scope == null ||
          !scope!.same(admitted.scope) ||
          runtime.phase != NativeOfflineWorkspacePhase.ready) {
        await _open(admitted.scope, admitted.create, generation);
      }
      if (!active(generation) ||
          runtime.phase != NativeOfflineWorkspacePhase.ready) {
        return;
      }
      await admission.confirm(admitted.scope);
      if (!active(generation)) return;
      scope = admitted.scope;
      _published();
    } catch (_) {
      if (active(generation)) {
        unavailable = true;
        notifyListeners();
      }
    }
  }

  void bind(ReadWorkspaceController controller) {
    if (_controller == controller) return;
    _controller?.removeListener(_published);
    _controller = controller;
    _savedRevision = -1;
    controller.addListener(_published);
    _published();
  }

  void unbind(ReadWorkspaceController controller) {
    if (_controller != controller) return;
    controller.removeListener(_published);
    _controller = null;
  }

  void _published() {
    final c = _controller, s = scope, generation = _generation;
    if (c == null ||
        s == null ||
        !active(generation) ||
        c.loading ||
        !c.signedIn ||
        !c.hasLoaded ||
        c.locallyHydrated ||
        c.message.isNotEmpty ||
        c.store.ownerId != s.owner ||
        c.publishedRevision == _savedRevision) {
      return;
    }
    final saved = NativeWorkspaceSnapshot(
      ownerId: s.owner,
      installId: s.install,
      epoch: s.epoch,
      savedAtMs: c.clock(),
      entries: c.store.entries,
      codes: c.store.visibleCodes(c.clock()),
      sources: c.store.sources,
      unassigned: c.store.visibleUnassigned(c.clock()),
    );
    try {
      runtime.publishAuthenticated(saved);
      _savedRevision = c.publishedRevision;
      unavailable = false;
    } catch (_) {
      unavailable = true;
    }
    notifyListeners();
  }

  void localLockChanged() {
    if (!locallyUnlocked()) {
      lock();
    } else {
      unawaited(discover());
    }
  }

  void lock() {
    ++_generation;
    scope = null;
    _savedRevision = -1;
    runtime.lock();
    if (!_disposed) notifyListeners();
  }

  Future<void> invalidate() {
    lock();
    // Queue after every in-flight admit, including one whose native reply has
    // not arrived. Read its owner at execution, never lose that durable grant.
    return _serial(() async {
      final owner = _admittedOwner;
      if (owner == null) return;
      await admission.invalidate(owner);
      _admittedOwner = null;
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_published);
    lock();
    super.dispose();
  }
}
