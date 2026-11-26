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
}

class OtpFormatException implements Exception {
  const OtpFormatException(this.error);
  final OtpFormatError error;
  @override
  String toString() => 'OtpFormatException(${error.name})';
}

enum OtpAlgorithm { sha1, sha256, sha512 }

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
  }) : _secret = Uint8List.fromList(secret) {
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

  /// A copy. Deliberately a method, not a field, so it is never serialized
  /// by accident.
  Uint8List secretBytes() => Uint8List.fromList(_secret);

  @override
  String toString() => 'OtpAccount(redacted)';
}
