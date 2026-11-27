import 'dart:typed_data';

import 'google_migration.dart';
import 'import_preview.dart';
import 'otp_account.dart';

/// In-memory scan collection only. Never saves an account before all QR parts
/// are present and reviewed. A repeated camera frame is idempotent; a conflicting
/// frame at the same index is refused without discarding collected parts.
final class MigrationScanCollection {
  final Map<int, MigrationBatch> _parts = {};
  int get collected => _parts.length;
  int get expected => _parts.isEmpty ? 0 : _size(_parts.values.first);
  bool get complete => expected > 0 && collected == expected;
  static int _size(MigrationBatch b) => b.batchSize < 1 ? 1 : b.batchSize;

  void scan(String text) {
    final incoming = parseMigrationUri(text);
    if (_size(incoming) > 100 ||
        incoming.batchIndex < 0 ||
        incoming.batchIndex >= _size(incoming)) {
      throw const OtpFormatException(OtpFormatError.tooLarge);
    }
    if (_parts.isNotEmpty) {
      final first = _parts.values.first;
      if (incoming.batchId != first.batchId ||
          incoming.version != first.version ||
          _size(incoming) != expected) {
        throw const OtpFormatException(OtpFormatError.conflictingMetadata);
      }
    }
    final prior = _parts[incoming.batchIndex];
    if (prior != null) {
      if (!_same(prior.accounts, incoming.accounts)) {
        throw const OtpFormatException(OtpFormatError.conflictingMetadata);
      }
      return;
    }
    if (_parts.values.fold<int>(
          incoming.accounts.length,
          (n, b) => n + b.accounts.length,
        ) >
        1000) {
      throw const OtpFormatException(OtpFormatError.tooLarge);
    }
    _parts[incoming.batchIndex] = incoming;
  }

  List<OtpAccount> reviewedAccounts() =>
      List.unmodifiable(assembleBatches(_parts.values.toList()));
  List<ImportPreviewItem> preview({
    Set<(String?, String)> existing = const {},
  }) => previewImport(reviewedAccounts(), existingKeys: existing);
  void clear() => _parts.clear();
  @override
  String toString() => 'MigrationScanCollection(redacted)';
}

bool _same(List<OtpAccount> a, List<OtpAccount> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i], y = b[i];
    if (x.issuer != y.issuer ||
        x.accountName != y.accountName ||
        x.algorithm != y.algorithm ||
        x.digits != y.digits ||
        x.period != y.period)
      return false;
    final Uint8List xs = x.secretBytes(), ys = y.secretBytes();
    try {
      if (xs.length != ys.length) return false;
      var difference = 0;
      for (var j = 0; j < xs.length; j++) {
        difference |= xs[j] ^ ys[j];
      }
      if (difference != 0) return false;
    } finally {
      xs.fillRange(0, xs.length, 0);
      ys.fillRange(0, ys.length, 0);
    }
  }
  return true;
}
