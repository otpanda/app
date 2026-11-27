import 'dart:typed_data';

import 'export_entry.dart';
import 'export_plan.dart';
import 'export_seal.dart';

/// One entry the owner approved at begin. The API freezes id, seed version and
/// the client key in the passkey action; label, account, issuer and catalog id
/// are NOT in the API digest, so the client holds them here and refuses a
/// response whose authenticated metadata differs.
final class ApprovedExportEntry {
  const ApprovedExportEntry({
    required this.entryId,
    required this.version,
    required this.label,
    required this.account,
    required this.issuer,
    required this.catalogId,
  });
  final String entryId, version;
  final String? label, account, issuer, catalogId;
}

final class ExportBegin {
  const ExportBegin({
    required this.ownerId,
    required this.deviceId,
    required this.generation,
    required this.entries,
    required this.unavailable,
    required this.handle,
  });
  final String ownerId, deviceId;
  final int generation;

  /// Sorted by entry id, exactly as the API returned them.
  final List<ApprovedExportEntry> entries;
  final List<String> unavailable;

  /// Opaque to this file: the passkey token and options for [ExportTransport.finish].
  final Object handle;
}

/// Primary composes this against the real routes and passkey bridge.
abstract interface class ExportTransport {
  /// POST export-begin. Throws on any non-200.
  Future<ExportBegin> begin({
    required String ephemeralKey,
    List<String>? entryIds,
  });

  /// Prompts the strong passkey step-up for [begin], then POSTs export-finish
  /// with the same key and the echoed `{entryId, version}` list. Returns the
  /// decoded JSON body. Throws [ExportAuthException] when the user cancels or
  /// the proof fails, [ExportChangedException] for 409 `changed`. Called once
  /// per begin; the source never calls it twice.
  Future<Map<String, Object?>> finish({
    required ExportBegin begin,
    required String ephemeralKey,
  });
}

/// The set or its metadata changed after the owner approved it. Nothing was
/// shown; start a new export on purpose.
final class ExportChangedException implements Exception {
  const ExportChangedException();
  @override
  String toString() => 'ExportChangedException';
}

/// The response could not be authenticated or did not match what was approved.
final class ExportRejectedException implements Exception {
  const ExportRejectedException();
  @override
  String toString() => 'ExportRejectedException';
}

/// Implemented by sources that hold an in-flight attempt, so the page can end
/// it when the app leaves the foreground or the page closes.
abstract interface class ExportCancelable {
  void cancel();
}

const _entryKeys = {
  'entryId',
  'version',
  'label',
  'account',
  'issuer',
  'catalogId',
  'algorithm',
  'digits',
  'period',
  'nonce',
  'ciphertext',
};

String? _optText(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  throw const ExportRejectedException();
}

/// Verifies and opens a finish response against what was approved. Every
/// plaintext buffer it creates is overwritten before returning or throwing.
/// Throws [ExportChangedException] when approved metadata differs,
/// [ExportRejectedException] for any other mismatch or failed authentication.
List<ExportedEntry> openSealedExport({
  required ExportEphemeralKey key,
  required ExportBegin begin,
  required Map<String, Object?> response,
}) {
  final buffers = <Uint8List>[];
  var done = false;
  ExportSession? session;
  try {
    if (response.length != 2 ||
        response['serverPublicKey'] is! String ||
        response['entries'] is! List) {
      throw const ExportRejectedException();
    }
    final list = response['entries'] as List;
    if (list.length != begin.entries.length) {
      throw const ExportRejectedException();
    }
    final action = exportActionDigest(
      ownerId: begin.ownerId,
      deviceId: begin.deviceId,
      generation: begin.generation,
      frozen: [
        for (final e in begin.entries) (entryId: e.entryId, version: e.version),
      ],
      ephemeralDigest: key.digest,
    );
    session = ExportSession.open(
      key: key,
      serverPublicKey: response['serverPublicKey'] as String,
      actionDigest: action,
      ephemeralDigest: key.digest,
    );
    final out = <ExportedEntry>[];
    for (var i = 0; i < list.length; i++) {
      final raw = list[i];
      final a = begin.entries[i];
      if (raw is! Map ||
          raw.length != _entryKeys.length ||
          !raw.keys.every(_entryKeys.contains)) {
        throw const ExportRejectedException();
      }
      if (raw['entryId'] != a.entryId || raw['version'] != a.version) {
        throw const ExportRejectedException();
      }
      final label = _optText(raw['label']),
          account = _optText(raw['account']),
          issuer = _optText(raw['issuer']),
          catalog = _optText(raw['catalogId']);
      if (label != a.label ||
          account != a.account ||
          issuer != a.issuer ||
          catalog != a.catalogId) {
        throw const ExportChangedException();
      }
      final digits = raw['digits'], period = raw['period'];
      if (digits is! int ||
          digits < 6 ||
          digits > 8 ||
          period is! int ||
          period < 1 ||
          period > 86400 ||
          raw['algorithm'] is! String ||
          raw['nonce'] is! String ||
          raw['ciphertext'] is! String) {
        throw const ExportRejectedException();
      }
      final algorithm = algorithmFromName(raw['algorithm'] as String);
      final secret = session.openEntry(
        ExportAadFields(
          ownerId: begin.ownerId,
          deviceId: begin.deviceId,
          generation: begin.generation,
          entryId: a.entryId,
          seedVersion: a.version,
          algorithm: raw['algorithm'] as String,
          digits: digits,
          period: period,
          label: label,
          account: account,
          issuer: issuer,
          catalogId: catalog,
        ),
        raw['nonce'] as String,
        raw['ciphertext'] as String,
      );
      buffers.add(secret);
      out.add(
        ExportedEntry(
          entryId: a.entryId,
          label: label,
          account: account,
          issuer: issuer,
          catalogId: catalog,
          algorithm: algorithm,
          digits: digits,
          period: period,
          secret: secret,
        ),
      );
    }
    done = true;
    return out;
  } on ExportChangedException {
    rethrow;
  } on ExportRejectedException {
    rethrow;
  } catch (_) {
    throw const ExportRejectedException();
  } finally {
    // On success the entries own the secret buffers; on any failure they are
    // overwritten here and nothing is returned.
    if (!done) {
      for (final b in buffers) {
        b.fillRange(0, b.length, 0);
      }
    }
    session?.dispose();
  }
}

/// [SeedExportSource] over the sealed export routes. Holds the ephemeral key
/// only for one attempt and never retries by itself: a failed or lost attempt
/// is reported and the owner must start a new one (new key, new passkey prompt).
final class SealedSeedExportSource
    implements ExportEntrySource, ExportCancelable {
  SealedSeedExportSource(
    this.transport, {
    this.entryIds,
    this.newKey = ExportEphemeralKey.generate,
  });
  final ExportTransport transport;
  final List<String>? entryIds;
  final ExportEphemeralKey Function() newKey;

  int _attempt = 0;
  int? _runningAttempt;
  ExportEphemeralKey? _key;

  @override
  ({bool available, String? reason}) get availability =>
      (available: true, reason: null);

  /// Ends the in-flight attempt: disposes the key and makes any late reply
  /// from the transport be dropped. Safe to call at any time and repeatedly.
  @override
  void cancel() {
    ++_attempt;
    _key?.dispose();
    _key = null;
  }

  @override
  Future<List<ExportedEntry>> exportEntries() async {
    // A cancelled attempt no longer blocks a new one.
    if (_runningAttempt != null && _runningAttempt == _attempt) {
      throw StateError('export already in progress');
    }
    final mine = ++_attempt;
    _runningAttempt = mine;
    bool live() => mine == _attempt;
    final key = newKey();
    _key = key;
    try {
      final begin = await transport.begin(
        ephemeralKey: key.publicBase64Url,
        entryIds: entryIds,
      );
      if (!live()) throw const ExportAuthException(ExportAuthOutcome.cancelled);
      if (begin.entries.isEmpty) throw const ExportRejectedException();
      final reply = await transport.finish(
        begin: begin,
        ephemeralKey: key.publicBase64Url,
      );
      // A reply that arrives after cancel is dropped without being opened.
      if (!live()) throw const ExportAuthException(ExportAuthOutcome.cancelled);
      final entries = openSealedExport(key: key, begin: begin, response: reply);
      if (!live()) {
        for (final e in entries) {
          e.dispose();
        }
        throw const ExportAuthException(ExportAuthOutcome.cancelled);
      }
      return entries;
    } finally {
      key.dispose();
      if (identical(_key, key)) _key = null;
      if (_runningAttempt == mine) _runningAttempt = null;
    }
  }
}
