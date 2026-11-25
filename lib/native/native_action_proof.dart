import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// Validation of a server-built assignment action string (v8 action v2) before
/// any OS prompt. Pure Dart. Native shows ONLY fields parsed from the hashed
/// string and signs only when every check passes.

String hashText(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

const maxActionBytes = 3072;

/// A device-proof challenge must expire within this window from now.
const maxProofLifetimeMs = 150000;
const _labelMax = 64, _otherMax = 128;

class ValidatedAssignmentAction {
  const ValidatedAssignmentAction({
    required this.entryLabel,
    required this.accountName,
    required this.serviceId,
    required this.recipients,
    required this.automations,
  });
  final String entryLabel, accountName, serviceId;
  final int recipients, automations;

  /// The readable prompt text (parsed fields only).
  String get prompt =>
      'Assign this code to $entryLabel ($accountName). Shared with '
      '$recipients ${recipients == 1 ? 'person' : 'people'}, $automations '
      '${automations == 1 ? 'automation' : 'automations'}. Cannot be undone.';
}

/// Returns null when any check fails: the caller must not prompt.
ValidatedAssignmentAction? validateAssignmentActionV2(
  String action, {
  required String intentId,
  required String ownerId,
  required String deviceId,
  required int generation,
  required String entryId,
  required String challengeActionDigest,
  required String challengePurpose,
  required String challengeKeyId,
  required String ownKeyId,
  required int challengeExpiresAt,
  required int nowMs,
}) {
  if (utf8.encode(action).length > maxActionBytes) return null;
  if (hashText(action) != challengeActionDigest) return null;
  if (challengePurpose != 'step-up' || challengeKeyId != ownKeyId) return null;
  if (challengeExpiresAt <= nowMs ||
      challengeExpiresAt > nowMs + maxProofLifetimeMs) {
    return null;
  }
  Object? v;
  try {
    v = jsonDecode(action);
  } on FormatException {
    return null;
  }
  if (v is! List || v.length != 19) return null;
  bool ok(Object? x, bool Function(Object?) f) => f(x);
  bool str(Object? x) => x is String && x.isNotEmpty;
  bool nonNeg(Object? x) => x is int && x >= 0;
  if (v[0] != 'otpanda-assignment' || v[1] is! int || v[1] != 2) return null;
  if (v[2] != intentId || v[3] != ownerId || v[4] != deviceId) return null;
  if (v[5] is! int || v[5] != generation) return null;
  if (v[8] != entryId) return null;
  if (!ok(v[6], str) || !ok(v[7], str) || !ok(v[9], nonNeg)) return null;
  if (!ok(v[10], str) || !ok(v[11], nonNeg) || !ok(v[12], nonNeg)) {
    return null;
  }
  if (!ok(v[13], nonNeg) || !ok(v[14], nonNeg)) return null;
  if (v[15] != true) return null;
  final label = v[16], account = v[17], service = v[18];
  if (label is! String || account is! String || service is! String) {
    return null;
  }
  if (label.isEmpty || label.length > _labelMax) return null;
  if (account.length > _otherMax || service.length > _otherMax) return null;
  // No control or bidi-override characters in anything shown to the user.
  final bad = RegExp(
    r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\u061c\ufeff]',
  );
  if (bad.hasMatch(label) || bad.hasMatch(account) || bad.hasMatch(service)) {
    return null;
  }
  return ValidatedAssignmentAction(
    entryLabel: label,
    accountName: account,
    serviceId: service,
    recipients: v[13] as int,
    automations: v[14] as int,
  );
}

/// Later-approval action digest (v8 5.2): the phone recomputes it from the
/// status row before any prompt. [target] is null for passkey-add.
String approvalActionDigest({
  required String changeId,
  required String kind,
  required String? target,
  required String ownerId,
  required int generation,
}) => hashText(
  jsonEncode([
    'enrolled-approval',
    changeId,
    kind,
    target,
    ownerId,
    generation,
  ]),
);

/// Digest for adopt (v8 3.2): hashText(['adopt-device-key-v1', digest]).
String adoptActionDigest(String keyDigest) =>
    hashText(jsonEncode(['adopt-device-key-v1', keyDigest]));

final _unsafeText = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\u061c\ufeff]',
);

/// Longest text the OS prompt may carry (host enforces the same cap).
const maxPromptTextLength = 300;

String _age(int requestedAtMs, int nowMs) {
  final sec = (nowMs - requestedAtMs) ~/ 1000;
  if (sec < 60) return 'just now';
  final min = sec ~/ 60;
  return min == 1 ? '1 minute ago' : '$min minutes ago';
}

/// Readable text for a later approval (display only, never in a digest), or
/// null for an unknown kind or requester kind, any control/bidi/zero-width
/// character in the shown strings, a request dated in the future, or a text
/// over the cap. The account email is shortened (never the fingerprint).
String? approvalPrompt({
  required String kind,
  required String accountEmail,
  required String? requesterLabel,
  required String requesterKind,
  required int requestedAtMs,
  required int nowMs,
  required String? fingerprint,
}) {
  if (requesterLabel != null && requesterLabel.isEmpty) requesterLabel = null;
  if (accountEmail.isEmpty || _unsafeText.hasMatch(accountEmail)) return null;
  if (requesterLabel != null &&
      (_unsafeText.hasMatch(requesterLabel) || requesterLabel.length > 64)) {
    return null;
  }
  if (requestedAtMs > nowMs + 60000) return null;
  final base = switch (requesterKind) {
    'web' => 'a browser',
    'android' => 'an Android phone',
    _ => null,
  };
  if (base == null) return null;
  final who = requesterLabel == null ? base : '$base ($requesterLabel)';
  final when = _age(requestedAtMs, nowMs);
  final email = accountEmail.length > 48
      ? '${accountEmail.substring(0, 47)}\u2026'
      : accountEmail;
  final text = switch (kind) {
    'passkey-add' =>
      'Allow a new passkey to be added to $email? Requested $when from '
          '$who. Only approve if you started this.',
    'device-key-add' when fingerprint != null =>
      'Add a new phone (fingerprint $fingerprint) to $email? Requested '
          '$when from $who. Compare the fingerprint on the new phone. Only '
          'approve if you are holding it.',
    _ => null,
  };
  if (text == null || text.length > maxPromptTextLength) return null;
  return text;
}

/// Readable text for adopting this phone's existing server-side key, or null
/// for an unsafe email. Same cap and sanitising as [approvalPrompt].
String? adoptPrompt(String accountEmail) {
  if (accountEmail.isEmpty || _unsafeText.hasMatch(accountEmail)) return null;
  final email = accountEmail.length > 48
      ? '${accountEmail.substring(0, 47)}\u2026'
      : accountEmail;
  return 'Use this phone as a sign-in device for $email? Only continue if '
      'you set up this phone.';
}
