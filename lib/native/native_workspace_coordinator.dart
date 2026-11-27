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
  // All opens and cold rediscovery are serialized. Stale cleanup can never
  // close a newer open that has already started.
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
    int generation, {
    bool Function()? stillCurrent,
  }) async {
    bool current() => active(generation) && (stillCurrent?.call() ?? true);
    if (!current()) return;
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
    if (!current()) {
      // A stale open must not retain a live database. A later cold discovery
      // uses durable local authority, independently of this server session.
      runtime.lock();
      if (active(generation)) unawaited(discover());
      return;
    }
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
  Future<void> admitAuthenticated(
    String owner, {
    bool Function()? stillCurrent,
  }) {
    final generation = _generation;
    return _serial(() => _admitAuthenticated(owner, generation, stillCurrent));
  }

  Future<void> _admitAuthenticated(
    String owner,
    int generation,
    bool Function()? stillCurrent,
  ) async {
    bool current() => active(generation) && (stillCurrent?.call() ?? true);
    if (!current()) return;
    try {
      final state = await custody.readOwnerState(owner);
      if (!current() || !state.enabled) return;
      _admittedOwner = owner;
      final admitted = await admission.admit(owner, state.epoch);
      if (!current()) return;
      if (scope == null ||
          !scope!.same(admitted.scope) ||
          runtime.phase != NativeOfflineWorkspacePhase.ready) {
        await _open(
          admitted.scope,
          admitted.create,
          generation,
          stillCurrent: current,
        );
      }
      if (!current() || runtime.phase != NativeOfflineWorkspacePhase.ready) {
        return;
      }
      await admission.confirm(admitted.scope);
      if (!current()) return;
      scope = admitted.scope;
      _published();
    } catch (_) {
      if (current()) {
        unavailable = true;
        notifyListeners();
      }
    }
  }

  bool _readsSuspended = false;
  void setReadsSuspended(bool value) {
    if (_readsSuspended == value) return;
    _readsSuspended = value;
    final controller = _controller;
    if (controller == null) return;
    controller.setExternalHold(value);
  }

  void bind(ReadWorkspaceController controller) {
    if (_controller == controller) return;
    _controller?.removeListener(_published);
    _controller = controller;
    _savedRevision = -1;
    controller.addListener(_published);
    controller.setExternalHold(_readsSuspended);
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
