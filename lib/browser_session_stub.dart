import 'browser_session_contract.dart';
import 'session_contract.dart';

BrowserSessionBridge createBrowserSession() => _Unsupported();

class _Unsupported implements BrowserSessionBridge {
  @override
  Future<void> get ready async {}
  @override
  String get status => 'unsupported';
  @override
  Future<void> start(String mode) async => throw const ClientFailure();
  @override
  Future<void> passkey() async => throw const ClientFailure();
  @override
  void clear() {}
  @override
  Future<SessionResponse> read(String path) async =>
      throw const ClientFailure();
}
