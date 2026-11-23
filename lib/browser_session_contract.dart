import 'session_contract.dart';

abstract interface class BrowserSessionBridge {
  Future<void> get ready;
  String get status;
  Future<void> start(String mode);
  Future<void> passkey();
  void clear();
  Future<SessionResponse> read(String path);
}
