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

/// Lasting sender rule actions, separate from one-code assignment.
abstract interface class RuleBridge {
  /// Raw JSON of GET /v1/manage/rules/capabilities. Throws on any failure or a
  /// session change while in flight. Parse with parseRulesCapability.
  Future<String> rulesCapabilities();
  Future<String> readRules();
  Future<void> deleteRule(String ruleId);
  Future<String> rulePrepare(String target);
  Future<String> ruleConfirm();
  Future<String> ruleReconcile();
  String get ruleState;
  void ruleDismiss();
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

/// Content-free realtime hints. The listener receives a reason ('connect' after
/// every open, 'changed' on a server hint) and must only trigger an ordinary
/// authenticated refresh; hints carry no data. Returns an unsubscribe function.
abstract interface class RealtimeBridge {
  void Function() realtimeSubscribe(void Function(String reason) listener);
}

/// Content-free nudges for the waiting browser. The listener gets 'open',
/// 'changed' or 'closed' and must only re-read the pending status through
/// [AuthEntryBridge.protectionContinue]('check'); the nudge carries no data and
/// grants nothing. Returns a stop function. Separate from [AuthEntryBridge] so
/// existing implementations are unaffected.
abstract interface class ProtectionWatchBridge {
  void Function() protectionWatch(void Function(String reason) listener);
}

/// New TOTP creation never exposes stored seed material.
abstract interface class TotpManagementBridge {
  /// [catalogId] is the optional catalogue association chosen in the picker.
  /// It is left out of the request entirely when null (a custom entry).
  Future<String> addTotp(
    String label,
    String account,
    String secret, {
    String? catalogId,
  });
  Future<SessionResponse> totpCode(String entryId);
}

/// Owned-entry edits. A separate capability: a bridge without it shows no edit
/// controls. Implementations throw when the change is not confirmed. They
/// never retry on their own, because the server may have already committed it.
abstract interface class EntryManagementBridge {
  Future<void> renameEntry(String entryId, String label);
  Future<void> updateAccount(String entryId, String? account);
}

/// Separate on purpose: delete has its own adapter and is offered only when
/// the bridge implements it.
abstract interface class EntryDeleteBridge {
  Future<void> deleteEntry(String entryId);
}

/// Optional: a bridge whose client can only sometimes create TOTP entries
/// (for example no passkey provider on this device). Shells hide the add
/// action instead of showing a dead button. Absent means always available.
abstract interface class TotpCreationCapability {
  bool get canAddTotp;
}

/// Private extra websites per entry, for the signed-in viewer only. A shared
/// recipient edits their own list, never the owner's. Replace semantics: read
/// first, send the whole list. Both throw when not confirmed and never retry.
abstract interface class EntryDomainsBridge {
  /// entryId -> exact HTTPS hosts. An entry with none is absent or empty.
  Future<Map<String, List<String>>> readEntryDomains();

  /// Replaces this viewer's list for one entry. Returns the normalized list
  /// that was sent.
  Future<List<String>> replaceEntryDomains(
    String entryId,
    List<String> domains,
  );
}

/// Memory-only generated-code batches. Never returns seeds.
abstract interface class TotpBatchBridge {
  Future<SessionResponse> totpBatch(
    List<String> entryIds, {
    required int windowSeconds,
  });
}

/// Optional bounded future-start extension. Old bridges remain current-only.
abstract interface class FutureTotpBatchBridge implements TotpBatchBridge {
  Future<SessionResponse> totpBatchFrom(
    List<String> entryIds, {
    required int windowSeconds,
    required int fromSeconds,
  });
}

/// Host holds a tab-only invite secret. It never crosses this interface.
abstract interface class SharingInviteBridge {
  bool get invitePending;
  Future<SessionResponse> acceptPendingInvite();
  void dismissInvite();
}

/// Explicit host capability; epoch is an opaque retirement marker, never a bearer.
abstract interface class SharingManagementBridge {
  bool get sharingAvailable;
  int get sharingEpoch;
  Future<SessionResponse> sharingPost(
    String path,
    Map<String, Object?> body,
    int epoch,
  );
}
