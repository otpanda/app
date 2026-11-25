/// Local validator for otpauth://totp QR payloads. It mirrors the API's
/// provisioning grammar (src/totp-uri.js) so a scan is refused here with a
/// clear message instead of failing later at the server. The validated URI is
/// sent unchanged as the setup key; nothing is rewritten or dropped. Nothing
/// here logs, stores or transmits anything.
class OtpauthImport {
  final String name;
  final String account;

  /// The full validated otpauth URI, including the secret. Never print it.
  final String uri;
  const OtpauthImport(this.name, this.account, this.uri);
  @override
  String toString() => 'OtpauthImport(redacted)';
}

enum OtpauthProblem {
  notOtpauth,
  notTotp,
  badSecret,
  badLabel,
  issuerMismatch,
  unsupportedAlgorithm,
  unsupportedDigits,
  unsupportedPeriod,
  unsupportedParameter,
  malformed,
}

/// Messages never include any part of the scanned content.
class OtpauthException implements Exception {
  final OtpauthProblem problem;
  const OtpauthException(this.problem);
  String get message => switch (problem) {
    OtpauthProblem.notOtpauth =>
      'That QR code is not an authenticator setup code.',
    OtpauthProblem.notTotp => 'Only time-based authenticator codes are supported. This one is counter-based (HOTP).',
    OtpauthProblem.badSecret =>
      'The setup key in this QR code is missing or not valid.',
    OtpauthProblem.badLabel => 'The account name in this QR code is not valid.',
    OtpauthProblem.issuerMismatch =>
      'This QR code names two different services, so it was not added.',
    OtpauthProblem.unsupportedAlgorithm =>
      'This code uses a hash algorithm OTPanda does not support.',
    OtpauthProblem.unsupportedDigits =>
      'This code uses a digit count OTPanda does not support (6 or 8).',
    OtpauthProblem.unsupportedPeriod =>
      'This code uses a refresh period OTPanda does not support.',
    OtpauthProblem.unsupportedParameter => 'This QR code has extra settings OTPanda does not support yet, so it was not added.',
    OtpauthProblem.malformed => 'That QR code could not be read.',
  };
  @override
  String toString() => 'OtpauthException(${problem.name})';
}

const _bad = OtpauthException(OtpauthProblem.malformed);
final _ws = RegExp(r'[\s\u0000-\u001f\u007f]');
final _badLabel = RegExp(r'[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069:]');
final _hex = RegExp(r'%(?![0-9a-fA-F]{2})');
final _path = RegExp(r'^otpauth://totp/([^/?#]+)\?([^#]+)$');
final _b32 = RegExp(r'^[A-Za-z2-7]+$');

/// Mirrors the API's Base32 decode limits: a canonical unpadded length
/// (length mod 8 in 0,2,4,5,7), zero trailing bits, and 10..128 bytes.
bool _canonicalSecretBytes(String secret) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  if (!const {0, 2, 4, 5, 7}.contains(secret.length % 8)) return false;
  final bytes = secret.length * 5 ~/ 8;
  if (bytes < 10 || bytes > 128) return false;
  final tailBits = secret.length * 5 % 8;
  if (tailBits != 0) {
    final last = alphabet.indexOf(secret[secret.length - 1].toUpperCase());
    if (last & ((1 << tailBits) - 1) != 0) return false;
  }
  return true;
}

final _period = RegExp(r'^[1-9][0-9]{0,4}$');

String _decode(String v) {
  if (_hex.hasMatch(v)) throw _bad;
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    throw _bad;
  }
}

String _label(String v) {
  if (v.isEmpty || v.length > 254 || v != v.trim() || _badLabel.hasMatch(v)) {
    throw const OtpauthException(OtpauthProblem.badLabel);
  }
  return v;
}

/// Validates [input] against the API grammar and returns it for prefill.
/// Refuses (never drops) unknown parameters, duplicates, malformed encoding,
/// issuer/label-prefix mismatches and values outside the API's limits.
OtpauthImport parseOtpauth(String input) {
  if (input.length > 2048 || _ws.hasMatch(input)) throw _bad;
  if (!input.startsWith('otpauth://')) {
    throw const OtpauthException(OtpauthProblem.notOtpauth);
  }
  if (!input.startsWith('otpauth://totp/')) {
    throw const OtpauthException(OtpauthProblem.notTotp);
  }
  final m = _path.firstMatch(input);
  if (m == null) throw _bad;
  final parts = _decode(m.group(1)!).split(':');
  if (parts.length > 2) throw const OtpauthException(OtpauthProblem.badLabel);
  final accountName = _label(parts.last.replaceFirst(RegExp(r'^ +'), ''));
  final prefix = parts.length == 2 ? _label(parts.first) : null;
  final params = <String, String>{};
  for (final e in m.group(2)!.split('&')) {
    final i = e.indexOf('=');
    if (i < 1) throw _bad;
    final k = _decode(e.substring(0, i)), v = _decode(e.substring(i + 1));
    if (!const {
      'secret',
      'issuer',
      'algorithm',
      'digits',
      'period',
    }.contains(k)) {
      throw const OtpauthException(OtpauthProblem.unsupportedParameter);
    }
    if (params.containsKey(k) || v.isEmpty) throw _bad;
    params[k] = v;
  }
  final secret = params['secret'];
  // 16+ base32 characters decode to at least 10 bytes; 208 is the API cap.
  if (secret == null ||
      secret.length > 208 ||
      !_b32.hasMatch(secret) ||
      !_canonicalSecretBytes(secret)) {
    throw const OtpauthException(OtpauthProblem.badSecret);
  }
  final issuer = params.containsKey('issuer')
      ? _label(params['issuer']!)
      : prefix;
  if (prefix != null && issuer != prefix) {
    throw const OtpauthException(OtpauthProblem.issuerMismatch);
  }
  if (!const {
    'SHA1',
    'SHA256',
    'SHA512',
  }.contains(params['algorithm'] ?? 'SHA1')) {
    throw const OtpauthException(OtpauthProblem.unsupportedAlgorithm);
  }
  if (!const {'6', '8'}.contains(params['digits'] ?? '6')) {
    throw const OtpauthException(OtpauthProblem.unsupportedDigits);
  }
  final period = params['period'] ?? '30';
  if (!_period.hasMatch(period) || int.parse(period) > 86400) {
    throw const OtpauthException(OtpauthProblem.unsupportedPeriod);
  }
  var name = issuer ?? accountName;
  if (name.length > 120) name = name.substring(0, 120);
  var account = accountName.length > 120
      ? accountName.substring(0, 120)
      : accountName;
  if (account == name) account = '';
  return OtpauthImport(name, account, input);
}

/// Manual entry: an otpauth URI, or a bare Base32 setup key as services show
/// it (spaces or hyphens between groups, any case, optional '=' padding).
/// A bare key carries no name, so the returned name and account are empty.
/// Returns null when [input] is not a valid key. Never reports content.
OtpauthImport? parseSetupKey(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  if (t.toLowerCase().startsWith('otpauth://')) {
    try {
      return parseOtpauth(t);
    } on OtpauthException {
      return null;
    }
  }
  final key = t
      .replaceAll(RegExp(r'[ -]'), '')
      .replaceFirst(RegExp(r'=+$'), '')
      .toUpperCase();
  if (key.length > 208 || !_b32.hasMatch(key) || !_canonicalSecretBytes(key)) {
    return null;
  }
  return OtpauthImport('', '', key);
}
