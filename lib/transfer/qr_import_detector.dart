/// What a scanned QR text is, decided from its scheme only. No secret is
/// parsed here and nothing is logged. The caller parses with the strict parser
/// for the kind. Formats register in [importQrDetectors]; file formats can join
/// later without touching the scanner.
enum ImportQrKind {
  /// otpauth://totp/... one account (also accepts HOTP so the existing parser
  /// can explain why it is refused).
  otpauthSingle,

  /// otpauth-migration://offline?data=... Google Authenticator export part.
  googleMigration,

  /// Anything else.
  unknown,
}

typedef ImportQrDetector = ImportQrKind? Function(String text);

ImportQrKind? _scheme(String text, String prefix, ImportQrKind kind) =>
    text.length >= prefix.length &&
        text.substring(0, prefix.length).toLowerCase() == prefix
    ? kind
    : null;

/// Order matters: the longer scheme is tested first because
/// "otpauth-migration://" does not start with "otpauth://", but keep it explicit.
final List<ImportQrDetector> importQrDetectors = [
  (t) => _scheme(t, 'otpauth-migration://', ImportQrKind.googleMigration),
  (t) => _scheme(t, 'otpauth://', ImportQrKind.otpauthSingle),
];

ImportQrKind detectImportQr(String text) {
  final t = text.trim();
  for (final d in importQrDetectors) {
    final k = d(t);
    if (k != null) return k;
  }
  return ImportQrKind.unknown;
}
