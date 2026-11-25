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
  sessionRevoke('session-revoke'),
  googleUnlink('google-unlink');

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

  /// Display hints from the server. [provider] is a best-effort name for the
  /// passkey manager (never proof of where the key is stored); [label] is the
  /// name the person chose. Either is null when unknown.
  final String? provider, label;
  const RecoveryPasskey(
    this.id,
    this.createdAt,
    this.lastUsedAt, {
    this.provider,
    this.label,
  });

  /// What the list shows first: the person's name, else the provider, else a
  /// plain "Passkey".
  String get title => label ?? provider ?? 'Passkey';
}

/// Longest passkey name the server accepts.
const passkeyLabelMax = 40;

/// Renames a passkey. A null [label] removes the name. This changes only what
/// is displayed, so it needs no passkey check. Same outcome rules as
/// [RecoveryBridge.recoveryChange].
abstract interface class PasskeyLabelBridge {
  Future<void> renamePasskey(String credentialId, String? label);
}

String? _shown(Object? v) =>
    v is String && v.isNotEmpty && v.length <= 80 ? v : null;

class RecoverySession {
  final String id, clientKind;
  final int createdAt;
  final int? lastUsedAt;
  final bool current;

  /// Self-reported by the session, closed lists, null until it describes
  /// itself. A label only, never an identity. [name] is the native device name.
  final String? browser, os, name;
  const RecoverySession(
    this.id,
    this.clientKind,
    this.createdAt,
    this.lastUsedAt,
    this.current, {
    this.browser,
    this.os,
    this.name,
  });

  static const _browsers = {
    'chrome': 'Chrome',
    'edge': 'Edge',
    'firefox': 'Firefox',
    'safari': 'Safari',
    'opera': 'Opera',
    'samsung': 'Samsung Internet',
  };
  static const _systems = {
    'android': 'Android',
    'windows': 'Windows',
    'mac': 'Mac',
    'ios': 'iOS',
    'linux': 'Linux',
    'chromeos': 'ChromeOS',
  };

  /// "Firefox on Linux", "Chrome", "Linux", or "Web" when nothing is known. A
  /// native client shows its device name, else "Android app".
  String get title {
    if (clientKind == 'android') return name ?? 'Android app';
    final b = _browsers[browser], o = _systems[os];
    if (b != null && o != null) return '$b on $o';
    return b ?? o ?? 'Web';
  }
}

String? _enum(Object? v, Set<String> allowed) =>
    v is String && allowed.contains(v) ? v : null;

String? _deviceName(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty || t.length > 60 ? null : t;
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
            provider: _shown(p['provider']),
            label: _shown(p['label']),
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
            browser: _enum(
              p['browser'],
              RecoverySession._browsers.keys.toSet(),
            ),
            os: _enum(p['os'], RecoverySession._systems.keys.toSet()),
            name: _deviceName(p['name']),
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
