import 'dart:typed_data';

/// Why an import or export was refused. Messages never contain input text.
enum OtpFormatError {
  malformed,
  unsupportedType,
  unsupportedAlgorithm,
  unsupportedDigits,
  unsupportedPeriod,
  badSecret,
  tooLarge,
  conflictingMetadata,
  incompleteBatch,
  notRepresentable,

  /// A well-formed container of a version this reader does not know.
  unsupportedVersion,

  /// A password-protected file. Decrypting is a separate, reviewed feature.
  encrypted,
}

final _unsafeLabel = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb]',
);

/// A label safe to show in a local preview, or null. Used for entries that
/// were not imported so people can tell which ones to move by hand. Control and
/// bidirectional characters, empty and over-long values give null.
String? displayableLabel(String? v) =>
    (v == null ||
        v.isEmpty ||
        v.length > OtpAccount.maxLabelLength ||
        _unsafeLabel.hasMatch(v))
    ? null
    : v;

class OtpFormatException implements Exception {
  const OtpFormatException(this.error);
  final OtpFormatError error;
  @override
  String toString() => 'OtpFormatException(${error.name})';
}

enum OtpAlgorithm { sha1, sha256, sha512 }

/// A parameter the source did not carry, so a default was applied. Shown to the
/// user at import and cleared when they edit that parameter. Never a secret.
enum OtpAssumption {
  algorithm,
  digits,
  period;

  /// Stable storage names. Persist these with the account when it is saved, so
  /// the "assumed" note survives restarts and edits.
  static List<String> encodeAll(Set<OtpAssumption> v) => [
    for (final a in OtpAssumption.values)
      if (v.contains(a)) a.name,
  ];

  /// Strict: an unknown or repeated name is refused, never ignored.
  static Set<OtpAssumption> decodeAll(Iterable<String> names) {
    final out = <OtpAssumption>{};
    for (final n in names) {
      final match = OtpAssumption.values.where((a) => a.name == n);
      if (match.isEmpty || !out.add(match.single)) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
    }
    return out;
  }
}

/// One time-based account. Immutable. The secret never appears in toString,
/// equality of previews or any error. Callers own where the bytes go next.
final class OtpAccount {
  static const minSecretBytes = 10, maxSecretBytes = 128;
  static const maxLabelLength = 254;

  OtpAccount({
    required this.issuer,
    required this.accountName,
    required Uint8List secret,
    this.algorithm = OtpAlgorithm.sha1,
    this.digits = 6,
    this.period = 30,
    Set<OtpAssumption> assumed = const {},
  }) : assumed = Set.unmodifiable(assumed),
       _secret = Uint8List.fromList(secret) {
    if (secret.length < minSecretBytes || secret.length > maxSecretBytes) {
      throw const OtpFormatException(OtpFormatError.badSecret);
    }
    if (digits != 6 && digits != 8) {
      throw const OtpFormatException(OtpFormatError.unsupportedDigits);
    }
    if (period < 1 || period > 86400) {
      throw const OtpFormatException(OtpFormatError.unsupportedPeriod);
    }
    for (final v in [accountName, ?issuer]) {
      if (v.isEmpty ||
          v.length > maxLabelLength ||
          v != v.trim() ||
          RegExp(
            r'[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb:]',
          ).hasMatch(v)) {
        throw const OtpFormatException(OtpFormatError.malformed);
      }
    }
  }

  final String? issuer;
  final String accountName;
  final OtpAlgorithm algorithm;
  final int digits;
  final int period;
  final Uint8List _secret;

  /// Parameters filled with a default because the import source lacked them.
  final Set<OtpAssumption> assumed;

  /// A copy with edited parameters. Each edited parameter stops being an
  /// assumption (the user has now stated it). Validation is the constructor's.
  OtpAccount withParameters({
    OtpAlgorithm? algorithm,
    int? digits,
    int? period,
  }) => OtpAccount(
    issuer: issuer,
    accountName: accountName,
    secret: _secret,
    algorithm: algorithm ?? this.algorithm,
    digits: digits ?? this.digits,
    period: period ?? this.period,
    assumed: {
      for (final a in assumed)
        if (!(a == OtpAssumption.algorithm && algorithm != null) &&
            !(a == OtpAssumption.digits && digits != null) &&
            !(a == OtpAssumption.period && period != null))
          a,
    },
  );

  /// A copy. Deliberately a method, not a field, so it is never serialized
  /// by accident.
  Uint8List secretBytes() => Uint8List.fromList(_secret);

  @override
  String toString() => 'OtpAccount(redacted)';
}
