import '../offline_totp/aegis_vault.dart';
import '../offline_totp/bitwarden.dart';
import '../offline_totp/google_migration.dart';
import '../offline_totp/otp_account.dart';
import '../offline_totp/otpauth_uri.dart';

/// What Google Authenticator will do differently with one account. Google
/// ignores settings its format cannot carry (decided by the user, Nov 26-27),
/// so these accounts are still exported, and the review says what changes.
enum GoogleExportChange { periodDropped, digitsAdjusted }

final class GoogleExportNote {
  const GoogleExportNote(this.issuer, this.accountName, this.change, this.from);
  final String? issuer;
  final String accountName;
  final GoogleExportChange change;

  /// The original period (seconds) or digit count.
  final int from;
}

/// Every account goes into the Google export. Accounts the format cannot carry
/// exactly (period other than 30 s, 7 digits) are written with Google's values
/// (30 s, and 6 digits for a 7-digit key) and listed in [notes] so the UI can
/// say Google will compute different codes for them. Nothing is dropped.
({List<OtpAccount> accounts, List<GoogleExportNote> notes}) planGoogleExport(
  List<OtpAccount> accounts,
) {
  final out = <OtpAccount>[], notes = <GoogleExportNote>[];
  for (final a in accounts) {
    if (isMigrationRepresentable(a)) {
      out.add(a);
      continue;
    }
    if (a.period != 30) {
      notes.add(
        GoogleExportNote(
          a.issuer,
          a.accountName,
          GoogleExportChange.periodDropped,
          a.period,
        ),
      );
    }
    if (a.digits != 6 && a.digits != 8) {
      notes.add(
        GoogleExportNote(
          a.issuer,
          a.accountName,
          GoogleExportChange.digitsAdjusted,
          a.digits,
        ),
      );
    }
    // The true period travels in the OTPanda extension field (Google ignores
    // it and shows 30 s). Only the digit count is changed for Google.
    out.add(a.digits == 6 || a.digits == 8 ? a : a.withParameters(digits: 6));
  }
  return (accounts: out, notes: notes);
}

/// Largest text a single export QR may carry. A QR holds at most 2953 bytes at
/// the lowest error correction; stay well under so phones scan it quickly.
const maxExportQrChars = 1800;

/// The QR texts to show, or null when nothing is exportable. Uses the strict
/// encoder, with the most accounts per QR that still fit [maxExportQrChars].
List<String>? googleExportUris(
  List<OtpAccount> exportable, {
  required int batchId,
}) {
  if (exportable.isEmpty) return null;
  for (var per = 10; per >= 1; per--) {
    final uris = encodeMigrationUris(
      exportable,
      batchId: batchId,
      perBatch: per,
      periodExtension: true,
    );
    if (uris.every((u) => u.length <= maxExportQrChars)) return uris;
  }
  throw const OtpFormatException(OtpFormatError.tooLarge);
}

enum ExportAuthOutcome { granted, cancelled, failed }

/// Holds the secrets for export only after a fresh strong reauth (passkey step-up
/// bound to the export action) and, for sealed server export, after decrypting
/// to a client ephemeral key. Implemented by primary against the real route.
/// Callers must never log, copy or persist what it returns.
abstract interface class SeedExportSource {
  /// True when this device/account can export at all, with a user-facing
  /// reason when not (for example the route is not deployed).
  ({bool available, String? reason}) get availability;

  /// Prompts the strong reauth, then returns every exportable TOTP account.
  /// Throws [ExportAuthException] when the user cancels or reauth fails; no
  /// secret is read before reauth succeeds.
  Future<List<OtpAccount>> exportAll();
}

final class ExportAuthException implements Exception {
  const ExportAuthException(this.outcome);
  final ExportAuthOutcome outcome;
  @override
  String toString() => 'ExportAuthException(${outcome.name})';
}

/// Text export formats. Every one contains live secrets: only hand the result
/// to a place the user chose (a saved file), never a log or clipboard by default.
enum ExportFileFormat { otpauthList, aegisPlain, bitwardenJson, bitwardenCsv }

String exportFileText(
  ExportFileFormat f,
  List<OtpAccount> accounts, {
  required String Function() newUuid,
}) => switch (f) {
  ExportFileFormat.otpauthList => accounts.map(encodeOtpauthUri).join('\n'),
  ExportFileFormat.aegisPlain => encodeAegisPlainVault(
    accounts,
    newUuid: newUuid,
  ),
  ExportFileFormat.bitwardenJson => encodeBitwardenJson(
    accounts,
    newUuid: newUuid,
  ),
  ExportFileFormat.bitwardenCsv => encodeBitwardenCsv(accounts),
};

/// Notes that every file export drops notes, icons, groups and favorites.
const exportMetadataNote =
    'Notes, icons, folders and favorites are not included.';
