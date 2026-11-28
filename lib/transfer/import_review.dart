import '../offline_totp/import_outcome.dart';
import '../offline_totp/import_preview.dart';
import '../offline_totp/otp_account.dart';

/// Whole-batch review state. Nothing here saves. Best-effort duplicates (same
/// issuer/account as one already held, or repeated in the batch) start skipped and
/// the user may include them. The model never stringifies a secret.
final class ImportReviewModel {
  ImportReviewModel(
    this._accounts, {
    Set<(String?, String)> existing = const {},
    this.skipped = const [],
  }) : items = previewImport(_accounts, existingKeys: existing) {
    include = [for (final i in items) !i.duplicateOfExisting];
  }
  final List<OtpAccount> _accounts;
  final List<ImportPreviewItem> items;

  /// Entries the source had that could not be imported, with the reason.
  final List<SkippedEntry> skipped;

  /// Build from a parsed file or scan, keeping the skip report.
  factory ImportReviewModel.fromOutcome(
    ImportOutcome o, {
    Set<(String?, String)> existing = const {},
  }) => ImportReviewModel(o.accounts, existing: existing, skipped: o.skipped);

  late final List<bool> include;

  int get selectedCount => include.where((v) => v).length;
  int get duplicateCount => items.where((i) => i.duplicateOfExisting).length;
  bool get hasNonDefaultPeriod => _accounts.any((a) => a.period != 30);

  void toggle(int i) => include[i] = !include[i];

  /// The accounts the user chose, in scan order.
  List<OtpAccount> selected() => [
    for (var i = 0; i < _accounts.length; i++)
      if (include[i]) _accounts[i],
  ];
  @override
  String toString() => 'ImportReviewModel(redacted)';
}

enum ImportSaveOutcome {
  /// Existing recovery, busy or unavailable journal blocks this new selection.
  blocked,

  /// Server refused a new admission before any finish was possible.
  capacity,

  /// Every selected account is now saved.
  saved,

  /// Nothing was saved and the server said so definitively.
  notSaved,

  /// The result is not known (lost reply, timeout). Do not retry blindly: the
  /// UI blocks resubmission and offers exact-attempt reconciliation.
  unknown,

  /// The user cancelled a confirmation before anything was committed.
  cancelled,
}

/// Saves a reviewed batch. [atomic] says whether this saver commits all
/// accounts or none under ONE confirmation. Released behaviour must use an
/// atomic saver for more than one account; see [SingleAccountSaver].
abstract interface class ImportSaver {
  bool get atomic;
  Future<ImportSaveOutcome> save(List<OtpAccount> accounts);
}

/// A durable saver exposes recovery without ever repeating a finish request.
abstract interface class RecoverableImportSaver implements ImportSaver {
  Future<ImportSaveOutcome> reconcile();
  Future<bool> acknowledgeShown();
}

/// Captures the exact durable terminal presented by one review, not a later result.
abstract interface class ImportAcknowledgementSource {
  Future<bool> Function() captureShownAcknowledgement();
}
