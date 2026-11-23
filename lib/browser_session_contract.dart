import 'session_contract.dart';

abstract interface class BrowserSessionBridge {
  Future<void> get ready;
  String get status;
  Future<void> start(String mode);
  Future<void> passkey();
  void clear();
  void logout();
  Future<SessionResponse> read(String path);
  Future<SessionResponse> organize(String method, String body);
  Future<SessionResponse> copied(String entryId, int createdAt);
}
