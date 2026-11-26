import 'otp_account.dart';

/// An entry that was not imported, and why. [position] is the 1-based entry or
/// line number. toString carries no label and no secret.
final class SkippedEntry {
  const SkippedEntry(
    this.position,
    this.error, {
    this.issuer,
    this.accountName,
  });
  final int position;
  final OtpFormatError error;

  /// Labels decoded from the entry when they are safe to display (see
  /// [displayableLabel]), so the user can tell which account did not migrate.
  /// Local preview only: never log or transmit them. No secret is ever kept.
  final String? issuer, accountName;
  @override
  String toString() => 'SkippedEntry($position, ${error.name})';
}

/// Accounts that imported plus entries that were refused individually. A
/// malformed container still throws; only per-entry unsupported content (HOTP,
/// MD5, unknown algorithm or digits, bad secret in a list) is skipped, and
/// always reported, never mapped to something else.
final class ImportOutcome {
  const ImportOutcome(this.accounts, this.skipped);
  final List<OtpAccount> accounts;
  final List<SkippedEntry> skipped;
  @override
  String toString() =>
      'ImportOutcome(${accounts.length} accounts, ${skipped.length} skipped)';
}
