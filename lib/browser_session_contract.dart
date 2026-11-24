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

/// App-owned email entry, separate from access/session authority.
abstract interface class AuthEntryBridge {
  String get email;
  Future<void> googleContinue(String action, [String proof = '']);
  Future<void> googleStart(bool remember);
  String get pendingLabel;
  Future<String> protectionContinue(String action);
  Future<String> security(
    String action, [
    bool enabled = false,
    String pendingId = '',
  ]);
  Future<void> signupEmail(String email, [String proof = '']);
}

abstract interface class FirstPasskeyBridge {
  bool get firstPasskeyAvailable;
  Future<void> firstPasskey();
}

abstract interface class AdditionalPasskeyBridge {
  Future<void> addPasskey();
}

/// Navigation identifiers only. No records, search, forms or proof state.
abstract interface class SessionViewBridge {
  int get restoredView;
  void setView(int view);
}

/// Renews only the current tab session; never supplies fresh security proof.
abstract interface class SessionContinuityBridge {
  Future<void> maintain();
  int get accessExpiresAt;
}
