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

/// Separate capability, not inferred from an ordinary signed-in bridge.
abstract interface class AssignmentBridge {
  Future<String> assignmentPrepare(String target);
  Future<String> assignmentConfirm();
  Future<String> assignmentReconcile();
  String get assignmentState;
  void assignmentDismiss();
}
