import '../session_contract.dart';
import 'native_seed_custody.dart';

/// Generates only codes for entries already visible in an unlocked workspace.
/// No network, seed extraction, session restoration or capability changes.
final class NativeWorkspaceCodeReader {
  NativeWorkspaceCodeReader({
    required this.custody,
    required this.owner,
    required this.epoch,
    required this.stillUnlocked,
    required this.clock,
  });
  final NativeSeedCustody custody;
  final String owner;
  final int epoch;
  final bool Function() stillUnlocked;
  final int Function() clock;
  bool _closed = false;
  int? _lastClock;
  int _readGeneration = 0;

  Future<List<ReceivedCode>> read(Iterable<ManagedEntry> visible) async {
    final generation = ++_readGeneration;
    bool alive() =>
        !_closed && generation == _readGeneration && stillUnlocked();
    if (!alive()) return const [];
    final now = clock();
    if (now < 0 || (_lastClock != null && now < _lastClock!)) return const [];
    _lastClock = now;
    final entries = {
      for (final e in visible)
        if (e.totp) e.id,
    };
    final catalog = await custody.readCatalog(owner);
    if (!alive() || !catalog.enabled || catalog.epoch != epoch) return const [];
    final result = <ReceivedCode>[];
    for (final entry in catalog.entries) {
      if (!entries.contains(entry.entryId) ||
          entry.epoch != epoch ||
          entry.seedVersion < entry.floor ||
          entry.seedVersion < entry.minAcceptedVersion ||
          entry.period < 1 ||
          entry.period > 86400 ||
          ![6, 7, 8].contains(entry.digits) ||
          catalog.pendingPurge.contains(entry.entryId)) {
        continue;
      }
      final start = (now ~/ (entry.period * 1000)) * entry.period * 1000;
      final end = start + entry.period * 1000;
      try {
        final value = await custody.generate(
          ownerId: owner,
          entryId: entry.entryId,
          seedVersion: entry.seedVersion,
          unixSeconds: now ~/ 1000,
        );
        final after = clock();
        if (!alive() || after < now) return const [];
        if (after >= end ||
            !RegExp('^[0-9]{${entry.digits}}\$').hasMatch(value)) {
          continue;
        }
        result.add(
          ReceivedCode.fromJson({
            'entryId': entry.entryId,
            'code': value,
            'receivedAt': start,
            'expiresAt': end,
          }),
        );
      } on CustodyException {
        // Never retain the last code after locked/missing/tamper/revoked state.
      }
    }
    final finalCatalog = await custody.readCatalog(owner);
    final finish = clock();
    if (!alive() ||
        finish < now ||
        !finalCatalog.enabled ||
        finalCatalog.epoch != epoch) {
      return const [];
    }
    _lastClock = finish;
    final current = {for (final e in finalCatalog.entries) e.entryId: e};
    return List.unmodifiable(
      result.where((code) {
        final before = catalog.entries
            .where((e) => e.entryId == code.entryId)
            .single;
        final after = current[code.entryId];
        return code.active(finish) &&
            after != null &&
            !finalCatalog.pendingPurge.contains(code.entryId) &&
            after.epoch == epoch &&
            after.seedVersion == before.seedVersion &&
            after.seedVersion >= after.floor &&
            after.seedVersion >= after.minAcceptedVersion &&
            after.period == before.period &&
            after.digits == before.digits &&
            after.algorithm == before.algorithm;
      }),
    );
  }

  void close() {
    _closed = true;
    ++_readGeneration;
  }

  @override
  String toString() => 'NativeWorkspaceCodeReader(redacted)';
}
