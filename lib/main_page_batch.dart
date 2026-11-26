import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_session_contract.dart';
import 'totp_batch_contract.dart';

/// Owns only memory-held generated codes. The workspace owns session and entry
/// authorization. All network work is initiated by a visible selection or an
/// expiring horizon, never a per-entry polling loop.
class MainPageBatchController extends ChangeNotifier {
  MainPageBatchController({
    required this.bridge,
    required this.policy,
    required this.active,
    int Function()? wallMilliseconds,
    int Function()? monotonicMilliseconds,
  }) {
    _wall = wallMilliseconds ?? () => DateTime.now().millisecondsSinceEpoch;
    _mono = monotonicMilliseconds ?? () => _clock.elapsedMilliseconds;
    if (policy.maxEntries < 1 ||
        policy.maxEntries > 49 ||
        policy.maxTotalCodes < policy.maxEntries) {
      throw ArgumentError('Invalid batch policy');
    }
    _wallStart = _wall() - _mono();
    store = BatchCodeStore(monotonicMilliseconds: () => _mono());
  }
  final TotpBatchBridge bridge;
  final BatchPolicy policy;
  final bool Function() active;
  late int Function() _wall, _mono;
  late int _wallStart;
  bool _foreground = true;
  bool get _safe {
    final difference = (_wall() - _wallStart - _mono()).abs();
    if (difference > 2000) {
      invalidate(notify: false);
      _wallStart = _wall() - _mono();
      return false;
    }
    return _foreground && active();
  }

  void foreground(bool value) {
    _foreground = value;
    if (!value) invalidate();
  }

  final Stopwatch _clock = Stopwatch()..start();
  late final BatchCodeStore store;
  List<String> _ids = [];
  bool busy = false, _disposed = false;
  int _generation = 0, _retryAt = 0, _successAt = 0, _lastRequest = -3000;
  String? error;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool needsEntry(String id) =>
      (!store.omitted.containsKey(id) || store.omissionRetryDue(id)) &&
      !store.hasCoverage(id);

  /// Warm-up attempts per entry and period (key: id/periodStart), so one
  /// entry, or a long-period one, never spends another entry's quota, and a
  /// new period or generation starts at zero.
  final _warmAttempts = <String, int>{};
  static const _warmHorizonMs = 15000;
  String? _warmKey(String id) {
    final c = store.current(id);
    return c == null ? null : '$id/${c.periodStartMs}';
  }

  /// Within the final fifteen seconds, current-only coverage gets a bounded
  /// early renewal attempt so a next code can already be held at the boundary.
  /// At most two warm attempts per entry/period, with global request spacing.
  bool _wantsWarm(String id) {
    if (!store.hasCoverage(id) || store.hasNextCode(id)) return false;
    final c = store.current(id);
    if (c == null || c.remainingMs > _warmHorizonMs) return false;
    return (_warmAttempts['$id/${c.periodStartMs}'] ?? 0) < 2;
  }

  /// Ms until a held, current-only entry comes inside the warm-up horizon.
  int _msToWarmHorizon() {
    var best = 1 << 30;
    for (final id in _ids) {
      if (!store.hasCoverage(id) || store.hasNextCode(id)) continue;
      final c = store.current(id);
      if (c == null) continue;
      final w = c.remainingMs - _warmHorizonMs;
      if (w > 0 && w < best) best = w;
    }
    return best;
  }

  bool needsRenewal(String id) =>
      needsEntry(id) ||
      (store.hasCoverage(id) &&
          (store.entryCoverageRemainingMs(id) <= 15000 || _wantsWarm(id)));

  void select(List<String> ids) {
    final next = ids.toSet().toList();
    if (listEquals(next, _ids)) return;
    _ids = next;
    _successAt = 0;
    _warmAttempts.clear();
    if (next.isNotEmpty) {
      refresh();
    } else {
      _notify();
    }
  }

  /// Reconcile an authenticated workspace refresh without blanking still-valid
  /// generated codes. The caller separately invalidates on owner/session loss.
  Set<String> _authorized = {};
  void retainAuthorized(Set<String> ids, {Set<String> changed = const {}}) {
    if (setEquals(_authorized, ids) && changed.isEmpty) return;
    _authorized = Set.of(ids);
    _generation++;
    busy = false;
    store.retainAuthorized(ids.difference(changed));
    _ids = _ids.where(ids.contains).toList();
    _warmAttempts.removeWhere(
      (key, _) => !ids.any((id) => key.startsWith('$id/')),
    );
  }

  void invalidate({bool notify = true}) {
    _generation++;
    _successAt = 0;
    _warmAttempts.clear();
    _ids = [];
    _authorized = {};
    store.clear();
    busy = false;
    error = null;
    if (notify) _notify();
  }

  void tick() {
    if (_safe &&
        _ids.isNotEmpty &&
        !busy &&
        _mono() >= _retryAt &&
        _mono() >= _successAt &&
        _ids.any(needsRenewal)) {
      refresh();
    }
    _notify();
  }

  Future<void> refresh() async {
    if (!_safe ||
        busy ||
        _ids.isEmpty ||
        _disposed ||
        _mono() < _retryAt ||
        _mono() < _successAt ||
        _mono() - _lastRequest < 3000) {
      return;
    }
    final targets = _ids.where(needsRenewal).toList();
    final order = {for (var i = 0; i < _ids.length; i++) _ids[i]: i};
    targets.sort((a, b) {
      final left = store.entryCoverageRemainingMs(a),
          right = store.entryCoverageRemainingMs(b);
      final expiry = left.compareTo(right);
      return expiry != 0 ? expiry : order[a]!.compareTo(order[b]!);
    });
    final selected = targets.take(policy.maxEntries).toList();
    if (selected.isEmpty) return;
    for (final id in selected) {
      if (_wantsWarm(id)) {
        final k = _warmKey(id);
        if (k != null) _warmAttempts[k] = (_warmAttempts[k] ?? 0) + 1;
      }
    }
    if (_warmAttempts.length > 128) _warmAttempts.clear();
    final generation = _generation;
    busy = true;
    _notify();
    try {
      _lastRequest = _mono();
      final request = store.begin(selected.toSet());
      final response = await bridge.totpBatch(
        selected,
        windowSeconds: policy.maxWindowSeconds,
      );
      if (_disposed || generation != _generation) return;
      if (response.status != 200) throw StateError('Codes unavailable');
      if (utf8.encode(response.body).length > 131072) {
        throw const FormatException();
      }
      store.accept(request, jsonDecode(response.body), policy: policy);
      error = null;
      _retryAt = 0;
      _successAt =
          _mono() +
          (_ids.any(_wantsWarm)
              ? 3000
              : ((store.coverageRemainingMs() - 1000).clamp(
                  3000,
                  15000,
                )).clamp(3000, _msToWarmHorizon().clamp(3000, 15000)));
    } catch (e) {
      if (generation == _generation) {
        error = 'Generated codes are waiting for your connection.';
        _retryAt =
            _mono() +
            (e is FormatException && e.message == 'Expired on arrival'
                ? 3000
                : 15000);
      }
    } finally {
      if (generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  BatchCode? current(String id) => _safe ? store.current(id) : null;
  int? expectedDigits(String id) => store.expectedDigits(id);
  BatchCode? tileCurrent(String id) => _safe ? store.tileCurrent(id) : null;
  bool awaitingBoundary(String id) => _safe && store.awaitingBoundary(id);
  int? get nextBoundaryDelayMs {
    if (!_safe) return null;
    int? next;
    for (final id in _ids) {
      final delay = store.nextBoundaryDelayMs(id);
      if (delay != null && (next == null || delay < next)) next = delay;
    }
    return next;
  }

  Future<bool> copy(String id) async {
    final code = tileCurrent(id);
    if (code == null || !code.copyable) return false;
    await Clipboard.setData(ClipboardData(text: code.value));
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    store.clear();
    _clock.stop();
    super.dispose();
  }
}
