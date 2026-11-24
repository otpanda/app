import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_session_contract.dart';
import 'session_contract.dart';

class _BrowserReadTransport implements SessionTransport {
  final BrowserSessionBridge bridge;
  const _BrowserReadTransport(this.bridge);
  @override
  Future<SessionResponse> getManagement(String path) => bridge.read(path);
  @override
  Future<void> close() async {}
}

/// No credentials or persistence. One bounded refresh reads five endpoints.
/// A view owns resume/background events and the visible-code clock.
class ReadWorkspaceController extends ChangeNotifier {
  final BrowserSessionBridge bridge;
  final int Function() clock;
  late final CodeStore store = CodeStore(_BrowserReadTransport(bridge));
  bool loading = false, suspended = false, _disposed = false;
  String message = '';
  bool rateLimited = false, sessionEnded = false, hasLoaded = false;
  int _epoch = 0, _nextRefreshAt = 0;
  ReadWorkspaceController({required this.bridge, int Function()? clock})
    : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  bool get signedIn => !sessionEnded && bridge.status == 'restored';
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
    loading = true;
    message = '';
    rateLimited = false;
    store.clear();
    _notify();
    try {
      await store.load(clock, includePrivateInbox: true);
      if (_disposed || epoch != _epoch) return;
      if (!signedIn) {
        store.clear();
      } else {
        hasLoaded = true;
      }
    } on ClientFailure catch (error) {
      if (_disposed || epoch != _epoch) return;
      store.clear();
      if (error.signedOut) {
        sessionEnded = true;
        bridge.clear();
      }
      rateLimited = error.status == 429;
      if (rateLimited) _nextRefreshAt = clock() + 60000;
      message = error.toString();
    } catch (_) {
      if (_disposed || epoch != _epoch) return;
      store.clear();
      message = 'Could not load codes. Try again.';
    } finally {
      if (!_disposed && epoch == _epoch) {
        loading = false;
        _notify();
      }
    }
  }

  void tick() {
    if (_disposed || suspended) return;
    if (store.sessionExpired(clock())) {
      sessionEnded = true;
      bridge.clear();
      clear();
      message = 'Your session ended. Sign in again.';
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

  void suspend() {
    suspended = true;
    clear();
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
