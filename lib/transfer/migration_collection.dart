import '../offline_totp/google_migration.dart';
import '../offline_totp/import_outcome.dart';
import '../offline_totp/otp_account.dart';

/// In-memory collection of Google export QR parts. Same rules as the primary
/// helper (idempotent repeats, one export at a time, bounded) but it keeps the
/// per-entry skip report ([ImportOutcome]) instead of dropping it. Saves nothing.
final class MigrationCollection {
  final Map<int, MigrationBatch> _parts = {};
  int get collected => _parts.length;
  int get expected => _parts.isEmpty ? 0 : _size(_parts.values.first);
  bool get complete => expected > 0 && collected == expected;
  static int _size(MigrationBatch b) => b.batchSize < 1 ? 1 : b.batchSize;

  void scan(String text) {
    final incoming = parseMigrationUri(text, skipUnsupported: true);
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
      if (!_same(prior, incoming)) {
        throw const OtpFormatException(OtpFormatError.conflictingMetadata);
      }
      return;
    }
    final total = _parts.values.fold<int>(
      incoming.accounts.length + incoming.skipped.length,
      (n, b) => n + b.accounts.length + b.skipped.length,
    );
    if (total > 1000) throw const OtpFormatException(OtpFormatError.tooLarge);
    _parts[incoming.batchIndex] = incoming;
  }

  /// Throws incompleteBatch until every part is present.
  ImportOutcome outcome() => assembleBatchesWithSkipped(_parts.values.toList());
  void clear() => _parts.clear();
  @override
  String toString() => 'MigrationCollection(redacted)';
}

bool _same(MigrationBatch a, MigrationBatch b) {
  if (a.accounts.length != b.accounts.length ||
      a.skipped.length != b.skipped.length) {
    return false;
  }
  for (var i = 0; i < a.accounts.length; i++) {
    final x = a.accounts[i], y = b.accounts[i];
    if (x.issuer != y.issuer ||
        x.accountName != y.accountName ||
        x.algorithm != y.algorithm ||
        x.digits != y.digits ||
        x.period != y.period) {
      return false;
    }
    final xs = x.secretBytes(), ys = y.secretBytes();
    try {
      if (xs.length != ys.length) return false;
      var d = 0;
      for (var j = 0; j < xs.length; j++) {
        d |= xs[j] ^ ys[j];
      }
      if (d != 0) return false;
    } finally {
      xs.fillRange(0, xs.length, 0);
      ys.fillRange(0, ys.length, 0);
    }
  }
  return true;
}
