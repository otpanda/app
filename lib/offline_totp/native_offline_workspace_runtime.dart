import 'package:flutter/foundation.dart';

import '../session_contract.dart';
import 'native_seed_custody.dart';
import 'native_workspace_code_reader.dart';
import 'native_workspace_snapshot.dart';
import 'native_workspace_unlock.dart';
import 'secret_store.dart';

enum NativeOfflineWorkspacePhase { locked, opening, ready, unavailable }

/// Local display lifetime, independent of the server login lifetime. Admission
/// comes from durable native owner/install/epoch state plus local app unlock.
/// Does not restore a session, enroll, provision, sync or grant management.
final class NativeOfflineWorkspaceRuntime extends ChangeNotifier {
  NativeOfflineWorkspaceRuntime({required this.clock});
  final int Function() clock;
  NativeOfflineWorkspacePhase phase = NativeOfflineWorkspacePhase.locked;
  NativeWorkspaceSnapshot? _snapshot;
  NativeWorkspaceUnlockSession? _session;
  NativeWorkspaceCodeReader? _codes;
  int _generation = 0;
  bool _disposed = false;
  bool Function()? _unlocked;
  List<ReceivedCode> _local = const [];

  NativeWorkspaceSnapshot? get snapshot =>
      phase == NativeOfflineWorkspacePhase.ready && _unlocked?.call() == true
      ? _snapshot
      : null;
  List<ReceivedCode> get visibleCodes {
    final saved = snapshot;
    if (saved == null) return const [];
    final totp = saved.entries
        .where((e) => e.totp && e.manage)
        .map((e) => e.id)
        .toSet();
    final current = {
      for (final c in saved.activeCodes(clock()))
        if (!totp.contains(c.entryId)) c.entryId: c,
    };
    for (final code in _local) {
      if (code.active(clock())) current[code.entryId] = code;
    }
    return List.unmodifiable(current.values);
  }

  Future<void> open({
    required SecretStore keys,
    required NativeSeedCustody custody,
    required String namespace,
    required String path,
    required String owner,
    required String install,
    required int epoch,
    required bool admittedFreshWorkspace,
    required bool Function() stillLocallyUnlocked,
  }) async {
    lock();
    if (_disposed) return;
    final generation = _generation;
    _unlocked = stillLocallyUnlocked;
    bool active() =>
        !_disposed && generation == _generation && stillLocallyUnlocked();
    phase = NativeOfflineWorkspacePhase.opening;
    notifyListeners();
    NativeWorkspaceUnlockSession? opened;
    try {
      opened = await NativeWorkspaceUnlockSession.open(
        keys: keys,
        namespace: namespace,
        path: path,
        owner: owner,
        install: install,
        epoch: epoch,
        admittedFreshWorkspace: admittedFreshWorkspace,
        stillUnlocked: active,
      );
      final saved = opened.cache.read();
      if (!active()) {
        opened.close();
        return;
      }
      _session = opened;
      _snapshot = saved;
      _codes = NativeWorkspaceCodeReader(
        custody: custody,
        owner: owner,
        epoch: epoch,
        stillUnlocked: active,
        clock: clock,
      );
      phase = NativeOfflineWorkspacePhase.ready;
      notifyListeners();
      await refreshLocalCodes();
    } catch (_) {
      opened?.close();
      if (active()) {
        _session = null;
        _snapshot = null;
        _local = const [];
        phase = NativeOfflineWorkspacePhase.unavailable;
        notifyListeners();
      }
    }
  }

  Future<void> refreshLocalCodes() async {
    final reader = _codes, saved = snapshot, generation = _generation;
    if (reader == null || saved == null) return;
    try {
      final codes = await reader.read(saved.entries.where((e) => e.manage));
      if (_disposed || generation != _generation || snapshot != saved) return;
      _local = codes;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _local = const [];
    }
    notifyListeners();
  }

  /// Only fresh authenticated data can update the cache. Caller supplies the
  /// admitted owner/install/epoch scope; cache validates all three again.
  void publishAuthenticated(NativeWorkspaceSnapshot saved) {
    final session = _session;
    if (_disposed ||
        session == null ||
        phase != NativeOfflineWorkspacePhase.ready ||
        _unlocked?.call() != true) {
      throw StateError('Local workspace unavailable');
    }
    session.cache.save(saved);
    _snapshot = saved;
    _local = const [];
    notifyListeners();
  }

  void lock() {
    ++_generation;
    _codes?.close();
    _codes = null;
    _session?.close();
    _session = null;
    _unlocked = null;
    _snapshot = null;
    _local = const [];
    phase = NativeOfflineWorkspacePhase.locked;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    lock();
    super.dispose();
  }

  @override
  String toString() => 'NativeOfflineWorkspaceRuntime(redacted)';
}
