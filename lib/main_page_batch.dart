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
  }) {
    store = BatchCodeStore(
      monotonicMilliseconds: () => _clock.elapsedMilliseconds,
    );
  }
  final TotpBatchBridge bridge;
  final BatchPolicy policy;
  final bool Function() active;
  final Stopwatch _clock = Stopwatch()..start();
  late final BatchCodeStore store;
  List<String> _ids = [];
  bool busy = false, _disposed = false;
  int _generation = 0, _retryAt = 0;
  String? error;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void select(List<String> ids) {
    final next = ids.take(policy.maxEntries).toList();
    if (listEquals(next, _ids)) return;
    _generation++;
    _ids = next;
    store.clear();
    busy = false;
    _retryAt = 0;
    if (next.isNotEmpty) {
      refresh();
    } else {
      _notify();
    }
  }

  void invalidate() {
    _generation++;
    _ids = [];
    store.clear();
    busy = false;
    error = null;
    _notify();
  }

  void tick() {
    if (active() &&
        _ids.isNotEmpty &&
        !busy &&
        _clock.elapsedMilliseconds >= _retryAt &&
        store.needsRefresh(leadMs: 15000)) {
      refresh();
    }
    _notify();
  }

  Future<void> refresh() async {
    if (!active() || busy || _ids.isEmpty || _disposed) return;
    final generation = _generation, request = store.begin(_ids.toSet());
    busy = true;
    _notify();
    try {
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
      _retryAt = _clock.elapsedMilliseconds + 15000;
    } catch (_) {
      if (generation == _generation) {
        error = 'Generated codes are waiting for your connection.';
        _retryAt = _clock.elapsedMilliseconds + 15000;
      }
    } finally {
      if (generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  BatchCode? current(String id) => store.current(id);
  Future<void> copy(String id) async {
    final code = store.current(id);
    if (!active() || code == null) return;
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
