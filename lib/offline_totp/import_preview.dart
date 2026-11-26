import 'otp_account.dart';

/// What a user sees before confirming an import. Contains no secret and no
/// value derived from it (no code, no hash, no prefix).
final class ImportPreviewItem {
  const ImportPreviewItem(
    this.issuer,
    this.accountName,
    this.algorithm,
    this.digits,
    this.period,
    this.secretBits,
    this.duplicateOfExisting,
  );
  final String? issuer;
  final String accountName;
  final OtpAlgorithm algorithm;
  final int digits, period, secretBits;
  final bool duplicateOfExisting;
}

/// [existingKeys] are (issuer, account) pairs already held; duplicates are
/// flagged so the caller can skip them. Within the batch a repeated identity is
/// flagged too (second occurrence onward).
List<ImportPreviewItem> previewImport(
  List<OtpAccount> incoming, {
  Set<(String?, String)> existingKeys = const {},
}) {
  final seen = {...existingKeys};
  return [
    for (final a in incoming)
      ImportPreviewItem(
        a.issuer,
        a.accountName,
        a.algorithm,
        a.digits,
        a.period,
        a.secretBytes().length * 8,
        !seen.add((a.issuer, a.accountName)),
      ),
  ];
}
