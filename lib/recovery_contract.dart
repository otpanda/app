/// Typed client contract for account recovery controls and the delayed
/// email-only escape hatch. The ceremonies (passkey step-up, new passkey
/// registration), tokens and the mailbox-binding secret live behind this
/// interface; Dart never sees them.
abstract interface class RecoveryBridge {
  /// False where the host cannot run the ceremonies (native, unsupported).
  bool get recoveryAvailable;

  /// Constant false until a verifier that enforces fresh local verification
  /// exists. The UI states this honestly and never offers the approval.
  bool get enrolledClientApprovalAvailable;

  Future<RecoveryStatus> recoveryStatus();

  /// One fresh passkey step-up bound to exactly this change. Throws
  /// [RecoveryRefused] when it definitely was not applied (cancelled check,
  /// refusal) and [RecoveryOutcomeUnknown] when it may have been.
  Future<void> recoveryChange(RecoveryChange change);

  Future<void> recoveryCancelRequest(String requestId);

  /// Unauthenticated email path. Responses never reveal whether an account or
  /// the escape hatch exists.
  Future<void> emailRecoveryStart(String email);
  Future<DateTime> emailRecoveryVerify(String email, String code);
  Future<void> emailRecoverySendCompletionCode(String email);

  /// Completion code, then a NEW passkey. No session is issued.
  Future<void> emailRecoveryComplete(String email, String code);
}

/// The server (or the bridge, before sending) definitely did not apply it.
class RecoveryRefused implements Exception {
  const RecoveryRefused();
}

/// The request may have been applied but its result could not be read (network
/// loss, timeout, server error, unreadable reply). Never report "nothing
/// changed" for this; re-read state or sign in to find out.
class RecoveryOutcomeUnknown implements Exception {
  const RecoveryOutcomeUnknown();
}

enum RecoveryKind {
  emailEscapeOn('email-escape-on'),
  emailEscapeOff('email-escape-off'),
  passkeyRevoke('passkey-revoke'),
  sessionRevoke('session-revoke');

  final String wire;
  const RecoveryKind(this.wire);
}

class RecoveryChange {
  final RecoveryKind kind;
  final String? target;
  final bool warningAccepted;
  const RecoveryChange(this.kind, {this.target, this.warningAccepted = false});
}

class RecoveryPasskey {
  final String id;
  final int createdAt;
  final int? lastUsedAt;
  const RecoveryPasskey(this.id, this.createdAt, this.lastUsedAt);
}

class RecoverySession {
  final String id, clientKind;
  final int createdAt;
  final int? lastUsedAt;
  final bool current;
  const RecoverySession(
    this.id,
    this.clientKind,
    this.createdAt,
    this.lastUsedAt,
    this.current,
  );
}

class EmailRecoveryRequest {
  final String requestId;
  final int requestedAt, availableAt;
  const EmailRecoveryRequest(
    this.requestId,
    this.requestedAt,
    this.availableAt,
  );
}

class RecoveryStatus {
  final bool escapeEnabled, blockedByGoogleProtection;
  final int delayDays;
  final List<RecoveryPasskey> passkeys;
  final List<RecoverySession> sessions;
  final EmailRecoveryRequest? request;
  const RecoveryStatus({
    required this.escapeEnabled,
    required this.blockedByGoogleProtection,
    required this.delayDays,
    required this.passkeys,
    required this.sessions,
    this.request,
  });

  /// Strict parse of GET /v1/manage/recovery/status. Throws FormatException on
  /// any unexpected shape so the UI never shows guessed state.
  factory RecoveryStatus.fromJson(Object? json) {
    int i(Object? v) => v is int ? v : throw const FormatException('number');
    String s(Object? v) =>
        v is String ? v : throw const FormatException('text');
    if (json is! Map) throw const FormatException('status');
    final e = json['emailEscape'];
    if (e is! Map || e['enabled'] is! bool) {
      throw const FormatException('escape');
    }
    final r = json['emailRecoveryRequest'];
    return RecoveryStatus(
      escapeEnabled: e['enabled'] as bool,
      blockedByGoogleProtection: e['blockedByGoogleProtection'] == true,
      delayDays: i(e['delayDays']),
      passkeys: [
        for (final p in json['passkeys'] as List)
          RecoveryPasskey(
            s((p as Map)['id']),
            i(p['createdAt']),
            p['lastUsedAt'] == null ? null : i(p['lastUsedAt']),
          ),
      ],
      sessions: [
        for (final p in json['sessions'] as List)
          RecoverySession(
            s((p as Map)['id']),
            s(p['clientKind']),
            i(p['createdAt']),
            p['lastUsedAt'] == null ? null : i(p['lastUsedAt']),
            p['current'] == true,
          ),
      ],
      request: r is Map
          ? EmailRecoveryRequest(
              s(r['requestId']),
              i(r['requestedAt']),
              i(r['availableAt']),
            )
          : null,
    );
  }
}
