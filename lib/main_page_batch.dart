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
    _wallStart = _wall();
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
      !store.omitted.containsKey(id) && !store.hasCoverage(id);

  void select(List<String> ids) {
    final next = ids.take(policy.maxEntries).toList();
    if (listEquals(next, _ids)) return;
    _ids = next;
    _successAt = 0;
    if (next.isNotEmpty) {
      refresh();
    } else {
      _notify();
    }
  }

  void invalidate({bool notify = true}) {
    _generation++;
    _successAt = 0;
    _ids = [];
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
        ((_ids.any((id) => !store.omitted.containsKey(id)) &&
                store.needsRefresh(leadMs: 15000)) ||
            _ids.any(needsEntry))) {
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
    final generation = _generation;
    busy = true;
    _notify();
    try {
      _lastRequest = _mono();
      final request = store.begin(_ids.toSet());
      final response = await bridge.totpBatch(
        List.of(_ids),
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
          _mono() + (store.coverageRemainingMs() - 1000).clamp(3000, 15000);
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
  Future<void> copy(String id) async {
    final code = current(id);
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code.value));
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
