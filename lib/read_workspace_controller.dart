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
  int _epoch = 0, _nextRefreshAt = 0, _nextAutomaticAt = 0;
  ReadWorkspaceController({required this.bridge, int Function()? clock})
    : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool get signedIn =>
      !sessionEnded &&
      ['restored', 'session-paused', 'restoring'].contains(bridge.status);
  bool get canRefresh =>
      !loading && !suspended && signedIn && clock() >= _nextRefreshAt;
  int get refreshWaitMs => (_nextRefreshAt - clock()).clamp(0, 60000);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() async {
    if (!canRefresh || _disposed) return;
    final epoch = ++_epoch;
    _nextRefreshAt = clock() + 15000;
    _nextAutomaticAt = clock() + 30000;
    loading = true;
    message = '';
    rateLimited = false;
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
        store = staged;
        hasLoaded = true;
      }
    } on ClientFailure catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (error.signedOut) {
        store.clear();
        hasLoaded = false;
        sessionEnded = true;
        bridge.clear();
      }
      rateLimited = error.status == 429;
      if (rateLimited) _nextRefreshAt = clock() + 60000;
      message = error.toString();
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      message =
          'Waiting for your connection. Updates will retry automatically.';
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        _notify();
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
      bridge.clear();
      clear();
      message = 'Your session ended. Sign in again.';
    }
    if (canRefresh && (!hasLoaded || clock() >= _nextAutomaticAt)) {
      refresh();
    }
    _notify();
  }

  void clear() {
    ++_epoch;
    loading = false;
    hasLoaded = false;
    store.clear();
    _notify();
  }

  void suspend({bool preserve = false}) {
    suspended = true;
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
    _disposed = true;
    ++_epoch;
    store.clear();
    super.dispose();
  }
}
