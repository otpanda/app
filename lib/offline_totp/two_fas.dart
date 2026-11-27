import 'dart:convert';

import 'base32.dart';
import 'import_outcome.dart';
import 'otp_account.dart';

/// 2FAS Authenticator backup (`.2fas`), plain (unencrypted) files only.
///
/// The schema below is read from the open-source Aegis importer for 2FAS
/// (TwoFASImporter.java): `schemaVersion` up to 4, `services[]` with `secret`
/// (Base32), `name` (the issuer) and `otp` {issuer, account, digits,
/// algorithm, period, tokenType TOTP/HOTP/STEAM, counter}. 2FAS does not
/// publish a specification, so this is a third-party reading, not a vendor
/// document. Export is NOT provided: the fields 2FAS requires on import are not
/// verified. A password-protected file (`servicesEncrypted`) is refused as
/// encrypted.
ImportOutcome parseTwoFasBackup(String text) {
  if (text.length > 8 << 20) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  Object? root;
  try {
    root = jsonDecode(text);
  } catch (_) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (root is! Map) throw const OtpFormatException(OtpFormatError.malformed);
  final v = root['schemaVersion'];
  if (v is! int || v < 1) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (v > 4) throw const OtpFormatException(OtpFormatError.unsupportedVersion);
  if (root['servicesEncrypted'] != null) {
    throw const OtpFormatException(OtpFormatError.encrypted);
  }
  final services = root['services'];
  if (services is! List) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (services.length > 5000) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  final accounts = <OtpAccount>[];
  final skipped = <SkippedEntry>[];
  for (var i = 0; i < services.length; i++) {
    final raw = services[i];
    try {
      accounts.add(_service(raw));
    } on OtpFormatException catch (e) {
      String? str(Object? m, String k) =>
          m is Map && m[k] is String ? m[k] as String : null;
      final otp = raw is Map ? raw['otp'] : null;
      final issuer = str(raw, 'name');
      skipped.add(
        SkippedEntry(
          i + 1,
          e.error,
          issuer: displayableLabel(
            (issuer == null || issuer.isEmpty) ? str(otp, 'issuer') : issuer,
          ),
          accountName: displayableLabel(
            [
              str(otp, 'account'),
              str(otp, 'label'),
              issuer,
            ].firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null),
          ),
        ),
      );
    }
  }
  if (accounts.isEmpty && skipped.isEmpty) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  return ImportOutcome(accounts, skipped);
}

OtpAccount _service(Object? s) {
  if (s is! Map) throw const OtpFormatException(OtpFormatError.malformed);
  final otp = s['otp'], secret = s['secret'];
  if (otp is! Map) throw const OtpFormatException(OtpFormatError.malformed);
  final type = otp['tokenType'];
  if (type != null && type != 'TOTP') {
    throw const OtpFormatException(OtpFormatError.unsupportedType);
  }
  if (secret is! String) {
    throw const OtpFormatException(OtpFormatError.badSecret);
  }
  final name = s['name'], oIssuer = otp['issuer'];
  final account = [
    otp['account'],
    otp['label'],
    name,
  ].firstWhere((v) => v is String && v.isNotEmpty, orElse: () => null);
  final issuer = (name is String && name.isNotEmpty)
      ? name
      : (oIssuer is String && oIssuer.isNotEmpty ? oIssuer : null);
  if (account is! String) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  final algo = otp['algorithm'], digits = otp['digits'], period = otp['period'];
  final algorithm = switch (algo) {
    null => OtpAlgorithm.sha1,
    'SHA1' => OtpAlgorithm.sha1,
    'SHA256' => OtpAlgorithm.sha256,
    'SHA512' => OtpAlgorithm.sha512,
    _ => throw const OtpFormatException(OtpFormatError.unsupportedAlgorithm),
  };
  if (digits != null && digits is! int) {
    throw const OtpFormatException(OtpFormatError.unsupportedDigits);
  }
  if (period != null && period is! int) {
    throw const OtpFormatException(OtpFormatError.unsupportedPeriod);
  }
  return OtpAccount(
    issuer: issuer,
    accountName: account,
    secret: decodeBase32(secret),
    algorithm: algorithm,
    digits: (digits as int?) ?? 6,
    period: (period as int?) ?? 30,
    assumed: {
      if (algo == null) OtpAssumption.algorithm,
      if (digits == null) OtpAssumption.digits,
      if (period == null) OtpAssumption.period,
    },
  );
}
