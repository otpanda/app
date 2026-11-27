import 'package:flutter/foundation.dart';

import '../offline_totp/native_seed_custody.dart';
import '../offline_totp/seed_enrollment_coordinator.dart';
import '../offline_totp/seed_sync_channel.dart';

/// Explicit enrollment UI lifetime. It does not create a replacement key, infer
/// account identity or enable opted-out custody. The root supplies its verified
/// owner and local-unlock fence, which are checked throughout the coordinator.
final class NativeOfflineEnrollment extends ChangeNotifier {
  NativeOfflineEnrollment({
    required this.enrollment,
    required this.custody,
    required this.sync,
    required this.isCurrent,
    required this.installId,
  });
  final SeedEnrollmentCoordinator enrollment;
  final NativeSeedCustody custody;
  final SeedSyncChannel sync;
  final Future<bool> Function(String) isCurrent;
  final Future<String> Function() installId;
  String? owner;
  bool busy = false, enabled = true, confirmed = false, _disposed = false;
  String? message;
  int _generation = 0;
  void bindOwner(String? value) {
    if (owner == value) return;
    ++_generation;
    owner = value;
    confirmed = false;
    message = null;
    _emit();
  }

  Future<void> refresh() async {
    final who = owner, generation = _generation;
    if (who == null) return;
    try {
      final state = await custody.readOwnerState(who);
      final journal = await sync.enrollmentJournal(who);
      if (_disposed || generation != _generation || !await isCurrent(who)) {
        return;
      }
      enabled = state.enabled;
      confirmed = journal?.phase == SeedEnrollmentPhase.confirmed;
      _emit();
    } catch (_) {
      if (!_disposed && generation == _generation) {
        message = 'Offline storage is unavailable. Existing data was kept.';
        _emit();
      }
    }
  }

  Future<void> setUp() async {
    final who = owner, generation = _generation;
    if (who == null || busy || !await isCurrent(who)) return;
    busy = true;
    message = null;
    _emit();
    try {
      final state = await custody.readOwnerState(who);
      if (!state.enabled || !await isCurrent(who)) return;
      final id = await installId();
      if (_disposed || generation != _generation || !await isCurrent(who)) {
        return;
      }
      final result = await enrollment.run(owner: who, installId: id);
      if (_disposed || generation != _generation || !await isCurrent(who)) {
        return;
      }
      confirmed =
          result.outcome == SeedEnrollOutcome.confirmed ||
          result.outcome == SeedEnrollOutcome.alreadyConfirmed;
      message = confirmed
          ? 'Offline key setup is complete. Codes must finish downloading before they work offline.'
          : 'Offline setup did not finish. Existing data was kept. Try again when connected.';
    } catch (_) {
      if (!_disposed && generation == _generation) {
        message = 'Offline setup is unavailable. Existing data was kept.';
      }
    } finally {
      busy = false;
      _emit();
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    super.dispose();
  }
}
