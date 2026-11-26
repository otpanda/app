import 'dart:convert';

import 'base32.dart';
import 'import_outcome.dart';
import 'otp_account.dart';

/// Aegis plain-text vault (documented in Aegis docs/vault.md, upper version 1,
/// content versions 1 to 3 seen in Aegis test data). Plain files only: a
/// password-protected vault is refused as [OtpFormatError.encrypted].
///
/// TOTP entries import with their own algorithm, digits and period. Anything
/// OTPanda cannot carry exactly (HOTP, Steam, mOTP, Yandex, 7 digits, a label
/// with a colon) is skipped and reported, never converted.
const maxAegisFileLength = 8 << 20, maxAegisEntries = 5000;

ImportOutcome parseAegisPlainVault(String text) {
  if (text.length > maxAegisFileLength) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  Object? root;
  try {
    root = jsonDecode(text);
  } catch (_) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (root is! Map || root['version'] is! int || root['header'] is! Map) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (root['version'] != 1) {
    throw const OtpFormatException(OtpFormatError.unsupportedVersion);
  }
  final header = root['header'] as Map;
  final db = root['db'];
  if (header['slots'] != null || header['params'] != null || db is String) {
    throw const OtpFormatException(OtpFormatError.encrypted);
  }
  if (db is! Map || db['version'] is! int) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (!const [1, 2, 3].contains(db['version'])) {
    throw const OtpFormatException(OtpFormatError.unsupportedVersion);
  }
  final entries = db['entries'];
  if (entries is! List) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  if (entries.length > maxAegisEntries) {
    throw const OtpFormatException(OtpFormatError.tooLarge);
  }
  final accounts = <OtpAccount>[];
  final skipped = <SkippedEntry>[];
  for (var i = 0; i < entries.length; i++) {
    try {
      accounts.add(_entry(entries[i]));
    } on OtpFormatException catch (e) {
      final raw = entries[i];
      skipped.add(
        SkippedEntry(
          i + 1,
          e.error,
          issuer: displayableLabel(
            raw is Map && raw['issuer'] is String
                ? raw['issuer'] as String
                : null,
          ),
          accountName: displayableLabel(
            raw is Map && raw['name'] is String ? raw['name'] as String : null,
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

OtpAccount _entry(Object? e) {
  if (e is! Map) throw const OtpFormatException(OtpFormatError.malformed);
  if (e['type'] != 'totp') {
    throw const OtpFormatException(OtpFormatError.unsupportedType);
  }
  final info = e['info'];
  final name = e['name'], issuer = e['issuer'];
  if (info is! Map ||
      name is! String ||
      (issuer != null && issuer is! String)) {
    throw const OtpFormatException(OtpFormatError.malformed);
  }
  final secret = info['secret'];
  if (secret is! String) {
    throw const OtpFormatException(OtpFormatError.badSecret);
  }
  final algo = info['algo'], digits = info['digits'], period = info['period'];
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
  final iss = (issuer as String?)?.isEmpty ?? true ? null : issuer as String;
  return OtpAccount(
    issuer: iss,
    accountName: name,
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

/// Aegis plain vault JSON. Contains every secret: call only behind strong
/// re-authentication. [newUuid] must return a fresh version 4 UUID per call
/// (the caller owns randomness, so this layer stays pure and testable).
String encodeAegisPlainVault(
  List<OtpAccount> accounts, {
  required String Function() newUuid,
}) => const JsonEncoder.withIndent('  ').convert({
  'version': 1,
  'header': {'slots': null, 'params': null},
  'db': {
    'version': 3,
    'entries': [
      for (final a in accounts)
        {
          'type': 'totp',
          'uuid': newUuid(),
          'name': a.accountName,
          'issuer': a.issuer ?? '',
          'note': '',
          'icon': null,
          'icon_mime': null,
          'icon_hash': null,
          'favorite': false,
          'info': {
            'secret': encodeBase32(a.secretBytes()),
            'algo': switch (a.algorithm) {
              OtpAlgorithm.sha1 => 'SHA1',
              OtpAlgorithm.sha256 => 'SHA256',
              OtpAlgorithm.sha512 => 'SHA512',
            },
            'digits': a.digits,
            'period': a.period,
          },
          'groups': <String>[],
        },
    ],
    'groups': <Object>[],
  },
});
