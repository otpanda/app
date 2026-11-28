import '../offline_totp/aegis_vault.dart';
import '../offline_totp/bitwarden.dart';
import '../offline_totp/import_outcome.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';
import '../offline_totp/two_fas.dart';

enum ImportFileFormat {
  otpauthList,
  aegisPlain,
  twoFasPlain,
  bitwardenJson,
  bitwardenCsv,
}

/// Picks a format from the text itself, never from the file name. Returns null
/// when nothing matches. Encrypted files are reported by the parsers as
/// [OtpFormatError.encrypted].
ImportFileFormat? detectImportFile(String text) {
  final t = text.startsWith('\ufeff') ? text.substring(1) : text;
  final s = t.trimLeft();
  if (s.startsWith('otpauth://')) return ImportFileFormat.otpauthList;
  if (s.startsWith('{')) {
    final head = s.length > 4096 ? s.substring(0, 4096) : s;
    // Bitwarden JSON carries "items"; Aegis carries "db" and "header";
    // 2FAS carries "services" (or "servicesEncrypted").
    if (RegExp(r'"services(Encrypted)?"\s*:').hasMatch(s)) {
      return ImportFileFormat.twoFasPlain;
    }
    if (RegExp(r'"header"\s*:').hasMatch(head) ||
        RegExp(r'"db"\s*:').hasMatch(s)) {
      return ImportFileFormat.aegisPlain;
    }
    if (RegExp(r'"items"\s*:').hasMatch(s)) {
      return ImportFileFormat.bitwardenJson;
    }
    return null;
  }
  final firstLine = s.split('\n').first.toLowerCase();
  if (firstLine.contains('login_totp') || firstLine.contains('totp')) {
    return ImportFileFormat.bitwardenCsv;
  }
  return null;
}

/// Parses with the preserved strict adapters. Throws [OtpFormatException] for a
/// damaged or encrypted container; per-entry gaps come back in the outcome.
ImportOutcome parseImportFile(String text) {
  final f = detectImportFile(text);
  if (f == null) throw const OtpFormatException(OtpFormatError.malformed);
  return switch (f) {
    ImportFileFormat.otpauthList => parseOtpauthList(text),
    ImportFileFormat.aegisPlain => parseAegisPlainVault(text),
    ImportFileFormat.twoFasPlain => parseTwoFasBackup(text),
    ImportFileFormat.bitwardenJson => parseBitwardenJson(text),
    ImportFileFormat.bitwardenCsv => parseBitwardenCsv(text),
  };
}
