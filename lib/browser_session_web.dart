import 'dart:js_interop';

import 'browser_session_contract.dart';
import 'session_contract.dart';

@JS('OTPandaSession')
external _Session get _session;

extension type _Session(JSObject _) implements JSObject {
  external JSPromise<JSAny?> get ready;
  external JSString status();
  external JSPromise<JSAny?> start(JSString mode);
  external JSPromise<JSAny?> passkey();
  external void clear();
  external void logout();
  external JSPromise<_ReadResponse> read(JSString path);
}

extension type _ReadResponse(JSObject _) implements JSObject {
  external JSNumber get status;
  external JSString get body;
}

BrowserSessionBridge createBrowserSession() => _Browser();

class _Browser implements BrowserSessionBridge {
  @override
  Future<void> get ready async {
    await _session.ready.toDart;
  }

  @override
  String get status => _session.status().toDart;
  @override
  Future<void> start(String mode) async {
    await _session.start(mode.toJS).toDart;
  }

  @override
  Future<void> passkey() async {
    await _session.passkey().toDart;
  }

  @override
  void clear() => _session.clear();
  @override
  void logout() => _session.logout();
  @override
  Future<SessionResponse> read(String path) async {
    final response = await _session.read(path.toJS).toDart;
    return SessionResponse(response.status.toDartInt, response.body.toDart);
  }
}
