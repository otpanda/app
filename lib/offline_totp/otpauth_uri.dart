import 'base32.dart';
import 'import_outcome.dart';
import 'otp_account.dart';

/// Strict Google Authenticator Key URI parser for TOTP. Mirrors the API's
/// totp-uri.js limits: no whitespace, only known parameters, no duplicates,
/// digits 6 or 8, secret 10..128 bytes, issuer prefix must equal the issuer
/// parameter. HOTP and anything unknown is refused, not downgraded.
OtpAccount parseOtpauthUri(String input) {
  try {
    if (input.length > 2048 ||
        RegExp(r'[\s\u0000-\u001f\u007f]').hasMatch(input)) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    if (input.startsWith('otpauth://hotp/')) {
      throw const OtpFormatException(OtpFormatError.unsupportedType);
    }
    final m = RegExp(r'^otpauth://totp/([^/?#]+)\?([^#]+)$').firstMatch(input);
    if (m == null) throw const OtpFormatException(OtpFormatError.malformed);
    final parts = _decode(m.group(1)!).split(':');
    if (parts.length > 2) {
      throw const OtpFormatException(OtpFormatError.malformed);
    }
    final account = parts.last.replaceFirst(RegExp(r'^ +'), '');
    final prefix = parts.length == 2 ? parts.first : null;
    final params = <String, String>{};
    for (final entry in m.group(2)!.split('&')) {
      final i = entry.indexOf('=');
      if (i < 1) throw const OtpFormatException(OtpFormatError.malformed);
      final k = _decode(entry.substring(0, i)),
          v = _decode(entry.substring(i + 1));
      if (!const [
            'secret',
            'issuer',
            'algorithm',
            'digits',
            'period',
          ].contains(k) ||
          params.containsKey(k) ||
          v.isEmpty) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
      params[k] = v;
    }
    final secret = params['secret'];
    if (secret == null) {
      throw const OtpFormatException(OtpFormatError.badSecret);
    }
    final issuer = params['issuer'] ?? prefix;
    if (prefix != null && issuer != prefix) {
      throw const OtpFormatException(OtpFormatError.conflictingMetadata);
    }
    final algorithm = switch (params['algorithm'] ?? 'SHA1') {
      'SHA1' => OtpAlgorithm.sha1,
      'SHA256' => OtpAlgorithm.sha256,
      'SHA512' => OtpAlgorithm.sha512,
      _ => throw const OtpFormatException(OtpFormatError.unsupportedAlgorithm),
    };
    final d = params['digits'] ?? '6';
    if (d != '6' && d != '8') {
      throw const OtpFormatException(OtpFormatError.unsupportedDigits);
    }
    final p = params['period'] ?? '30';
    if (!RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(p)) {
      throw const OtpFormatException(OtpFormatError.unsupportedPeriod);
    }
    return OtpAccount(
      issuer: issuer,
      accountName: account,
      secret: decodeBase32(secret),
      algorithm: algorithm,
      digits: int.parse(d),
      period: int.parse(p),
      assumed: {
        if (!params.containsKey('algorithm')) OtpAssumption.algorithm,
        if (!params.containsKey('digits')) OtpAssumption.digits,
        if (!params.containsKey('period')) OtpAssumption.period,
      },
    );
  } on OtpFormatException {
    rethrow;
  } catch (_) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
}

String _decode(String v) {
  if (RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(v)) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  return Uri.decodeComponent(v);
}

/// Export a single account as a standard Key URI. The result contains the
/// secret: only call it behind the strong re-authentication gate.
String encodeOtpauthUri(OtpAccount a) {
  final label = a.issuer == null
      ? Uri.encodeComponent(a.accountName)
      : '${Uri.encodeComponent(a.issuer!)}:${Uri.encodeComponent(a.accountName)}';
  final q = <String>[
    'secret=${encodeBase32(a.secretBytes())}',
    if (a.issuer != null) 'issuer=${Uri.encodeComponent(a.issuer!)}',
    'algorithm=${switch (a.algorithm) {
      OtpAlgorithm.sha1 => 'SHA1',
      OtpAlgorithm.sha256 => 'SHA256',
      OtpAlgorithm.sha512 => 'SHA512',
    }}',
    'digits=${a.digits}',
    'period=${a.period}',
  ];
  return 'otpauth://totp/$label?${q.join('&')}';
}

/// One Key URI per line, newline separated. Contains secrets.
String encodeOtpauthList(List<OtpAccount> accounts) =>
    '${accounts.map(encodeOtpauthUri).join('\n')}\n';

/// Parse a text list of Key URIs (as exported by several apps). Blank lines
/// and surrounding whitespace are ignored. A line that is not a supported
/// totp URI is skipped and reported by line number, never guessed at.
ImportOutcome parseOtpauthList(String text) {
  if (text.length > 1 << 20) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  final accounts = <OtpAccount>[];
  final skipped = <SkippedEntry>[];
  final lines = text.split(RegExp(r'\r\n|\n|\r'));
  if (lines.length > 5000) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    try {
      accounts.add(parseOtpauthUri(line));
    } on OtpFormatException catch (e) {
      final (issuer, name) = _labelOf(line);
      skipped.add(
        SkippedEntry(i + 1, e.error, issuer: issuer, accountName: name),
      );
    }
  }
  if (accounts.isEmpty && skipped.isEmpty) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  return ImportOutcome(accounts, skipped);
}

/// Best-effort display labels from a URI we refused, for the skipped preview.
(String?, String?) _labelOf(String line) {
  final m = RegExp(r'^otpauth://[a-z]+/([^/?#]+)').firstMatch(line);
  if (m == null) return (null, null);
  try {
    final parts = Uri.decodeComponent(m.group(1)!).split(':');
    if (parts.length == 1) return (null, displayableLabel(parts[0].trim()));
    if (parts.length == 2) {
      return (
        displayableLabel(parts[0].trim()),
        displayableLabel(parts[1].trim()),
      );
    }
  } catch (_) {}
  return (null, null);
}
