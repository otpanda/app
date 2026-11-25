import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_session_contract.dart';
import 'session_contract.dart';

class _BrowserReadTransport implements SessionTransport {
  final BrowserSessionBridge bridge;
  final bool Function()? active;
  const _BrowserReadTransport(this.bridge, [this.active]);
  @override
  Future<SessionResponse> getManagement(String path) => active?.call() == false
      ? Future.value(const SessionResponse(503, '{}'))
      : bridge.read(path);
  @override
  Future<void> close() async {}
}

/// No credentials or persistence. One bounded refresh reads five endpoints.
/// A view owns resume/background events and the visible-code clock.
class ReadWorkspaceController extends ChangeNotifier {
  final BrowserSessionBridge bridge;
  final int Function() clock;
  late CodeStore store = CodeStore(_BrowserReadTransport(bridge));
  bool loading = false, suspended = false, _disposed = false;
  String message = '';
  bool rateLimited = false, sessionEnded = false, hasLoaded = false;
  int publishedRevision = 0;
  bool _transportLost = false, _readLost = false;
  bool get connectionLost => _transportLost || _readLost;
  int _readFailures = 0;
  Timer? _readRetryTimer, _readLossTimer;
  int _epoch = 0, _nextRefreshAt = 0;
  void Function()? _unsubscribeRealtime;
  Timer? _hintTimer;
  bool _hintPending = false;
  ReadWorkspaceController({required this.bridge, int Function()? clock})
    : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool get signedIn =>
      !sessionEnded &&
      ['restored', 'session-paused', 'restoring'].contains(bridge.status);
  bool get canRefresh =>
      !loading && !suspended && signedIn && clock() >= _nextRefreshAt;
  int get refreshWaitMs => (_nextRefreshAt - clock()).clamp(0, 60000);

  /// Subscribes to content-free realtime hints while signed in and visible.
  /// Idempotent. A hint only asks for the ordinary refresh, so every existing
  /// rule (refresh gate, epoch guard, 401 handling) still applies.
  void _ensureRealtime() {
    if (_unsubscribeRealtime != null || _disposed || suspended || !signedIn) {
      return;
    }
    if (bridge is! RealtimeBridge) return;
    _unsubscribeRealtime = (bridge as RealtimeBridge).realtimeSubscribe(
      _onHint,
    );
  }

  void _stopRealtime() {
    _transportLost = false;
    final stop = _unsubscribeRealtime;
    _unsubscribeRealtime = null;
    _hintTimer?.cancel();
    _hintTimer = null;
    _hintPending = false;
    stop?.call();
  }

  void _onHint(String reason) {
    if (_disposed || suspended || !signedIn) return;
    if (reason == 'connection-lost' || reason == 'connection-restored') {
      _transportLost = reason == 'connection-lost';
      _notify();
      return;
    }
    if (reason != 'connect' && reason != 'changed') return;
    _hintPending = true;
    _drainHint();
  }

  /// One trailing refresh: runs now if the gate is open, otherwise once when
  /// it opens. Many hints collapse into one request.
  void _drainHint() {
    if (!_hintPending || _disposed) return;
    if (suspended || !signedIn) {
      _hintPending = false;
      return;
    }
    if (loading) return; // refresh() drains again when it finishes
    final wait = _nextRefreshAt - clock();
    if (wait <= 0) {
      _hintPending = false;
      refresh();
    } else {
      _hintTimer ??= Timer(Duration(milliseconds: wait), () {
        _hintTimer = null;
        _drainHint();
      });
    }
  }

  void _cancelReadRetry({bool reset = true}) {
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    _readLossTimer?.cancel();
    _readLossTimer = null;
    if (reset) {
      _readFailures = 0;
      _readLost = false;
    }
  }

  void _retryFailedRead([int? retryAfterSeconds]) {
    if (_disposed || suspended || !signedIn) return;
    _readFailures++;
    final delay = (15000 * (1 << (_readFailures - 1).clamp(0, 2))).clamp(
      15000,
      60000,
    );
    final headerDelay = retryAfterSeconds == null
        ? 0
        : retryAfterSeconds.clamp(0, 300) * 1000;
    final next = clock() + (headerDelay > delay ? headerDelay : delay);
    if (_nextRefreshAt < next) _nextRefreshAt = next;
    _readLossTimer ??= Timer(const Duration(seconds: 120), () {
      _readLossTimer = null;
      if (_disposed || suspended || !signedIn || _readFailures == 0) return;
      _readLost = true;
      _notify();
    });
    _readRetryTimer?.cancel();
    _readRetryTimer = Timer(
      Duration(milliseconds: (_nextRefreshAt - clock()).clamp(0, 2147483647)),
      () {
        _readRetryTimer = null;
        if (_disposed || suspended || !signedIn) return;
        refresh();
      },
    );
  }

  // Server-confirmed entry edits not yet seen in a read that started after them.
  // A read already in flight can still return the old label; the edit is laid
  // over it so the list never goes back.
  final Map<String, ({String? service, String? account})> _confirmed = {};
  int _confirmedCount = 0;

  /// The server confirmed this rename and/or account change: show it now.
  /// No request is made here. A normal refresh still follows and reconciles.
  void applyEntryEdit(String id, {String? service, String? account}) {
    if (_disposed || !hasLoaded) return;
    final prior = _confirmed[id];
    _confirmed[id] = (
      service: service ?? prior?.service,
      account: account ?? prior?.account,
    );
    _confirmedCount++;
    store.replaceEntry(id, service: service, account: account);
    publishedRevision++;
    _notify();
  }

  /// Explicit local mutation invalidation, coalesced behind the existing gate.
  void refreshAfterMutation() {
    if (_disposed || suspended || !signedIn) return;
    _hintPending = true;
    _drainHint();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (!canRefresh || _disposed) return;
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    final epoch = ++_epoch;
    _nextRefreshAt = clock() + 15000;
    loading = true;
    message = '';
    rateLimited = false;
    final confirmedAtStart = _confirmedCount;
    final staged = CodeStore(
      _BrowserReadTransport(bridge, () => !_disposed && epoch == _epoch),
    );
    _notify();
    try {
      await staged.load(clock, includePrivateInbox: true);
      if (_disposed || epoch != _epoch) return;
      if (!signedIn) {
        store.clear();
      } else {
        if (bridge is SessionContinuityBridge) {
          staged.updateSessionExpiry(
            (bridge as SessionContinuityBridge).accessExpiresAt,
            clock(),
          );
        }
        // A read that began after the last confirmed edit already carries it.
        // An older one may predate it, so the edits are laid over it.
        if (confirmedAtStart == _confirmedCount) {
          _confirmed.clear();
        } else {
          _confirmed.forEach(
            (id, v) =>
                staged.replaceEntry(id, service: v.service, account: v.account),
          );
        }
        store = staged;
        publishedRevision++;
        hasLoaded = true;
        _cancelReadRetry();
      }
    } on ClientFailure catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (error.signedOut) {
        store.clear();
        hasLoaded = false;
        sessionEnded = true;
        _stopRealtime();
        _cancelReadRetry();
        bridge.clear();
      }
      rateLimited = error.status == 429;
      if (rateLimited) _nextRefreshAt = clock() + 60000;
      message = error.toString();
      if (!error.signedOut) _retryFailedRead(error.retryAfterSeconds);
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      message =
          'Waiting for your connection. Updates will retry automatically.';
      _retryFailedRead();
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        _notify();
        _drainHint();
      }
    }
  }

  void tick() {
    if (_disposed || suspended) return;
    if (bridge is SessionContinuityBridge) {
      store.updateSessionExpiry(
        (bridge as SessionContinuityBridge).accessExpiresAt,
        clock(),
      );
      // Expired access hides records through CodeStore's clock, but is not
      // proof that the separate refresh session has ended.
      if (store.sessionExpired(clock())) {
        _notify();
        return;
      }
    }
    if (store.sessionExpired(clock())) {
      sessionEnded = true;
      _stopRealtime();
      bridge.clear();
      clear();
      message = 'Your session ended. Sign in again.';
    }
    _ensureRealtime();
    _notify();
  }

  void clear() {
    ++_epoch;
    loading = false;
    hasLoaded = false;
    _transportLost = false;
    _confirmed.clear();
    _cancelReadRetry();
    store.clear();
    _notify();
  }

  void suspend({bool preserve = false}) {
    suspended = true;
    _cancelReadRetry();
    _stopRealtime();
    if (preserve) {
      ++_epoch;
      loading = false;
      _notify();
    } else {
      clear();
    }
  }

  void resetSession() {
    clear();
    sessionEnded = false;
    suspended = false;
    message = '';
    _nextRefreshAt = 0;
  }

  void resume() {
    if (_disposed) return;
    suspended = false;
    if (bridge is SessionContinuityBridge) {
      store.updateSessionExpiry(
        (bridge as SessionContinuityBridge).accessExpiresAt,
        clock(),
      );
    }
    if (!signedIn) clear();
    _ensureRealtime();
    _notify();
  }

  bool canCopyAssigned(ReceivedCode code) =>
      !suspended && signedIn && store.visibleCodes(clock()).contains(code);
  bool canCopyPrivate(UnassignedCode code) =>
      !suspended && signedIn && store.visibleUnassigned(clock()).contains(code);

  Future<void> copyAssigned(ReceivedCode code) async {
    if (canCopyAssigned(code)) {
      await Clipboard.setData(ClipboardData(text: code.value));
    }
  }

  Future<void> copyPrivate(UnassignedCode code) async {
    if (canCopyPrivate(code)) {
      await Clipboard.setData(ClipboardData(text: code.value));
    }
  }

  @override
  void dispose() {
    _stopRealtime();
    _cancelReadRetry();
    _disposed = true;
    ++_epoch;
    store.clear();
    super.dispose();
  }
}
