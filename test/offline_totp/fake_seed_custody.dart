import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:otpanda_client/offline_totp.dart';

/// In-memory test double for [NativeSeedCustody]. It provides NO
/// confidentiality and no hardware or OS protection: seeds sit in plain memory.
/// A keyed MAC over the metadata (AAD) and seed stands in for an AEAD tag so
/// tests can observe tamper, swap and wrong-key behaviour. It reports
/// [reportedProtection] only as a documented test seam so the contract can be
/// exercised; that value is not evidence about any real store.
///
/// Two kinds of state, as in a real adapter: the secret store (records; needs
/// the store unlocked, available and keyed) and non-secret metadata (epochs,
/// version floors, snapshot order, pending purges), which is always writable
/// so a logical deny never waits for the store.
final class FakeSeedCustody implements NativeSeedCustody {
  FakeSeedCustody({
    List<int>? key,
    this.reportedProtection = CustodyProtection.osEncrypted,
  }) : _key = key ?? List.filled(32, 7);

  final CustodyProtection reportedProtection;
  List<int>? _key;
  Future<void> Function()? afterGenerate;
  bool unavailable = false, locked = false;

  /// Simulates unreadable or unwritable durable metadata.
  bool metadataDown = false;
  String unavailableReason = 'test double: no store';

  // secret store
  final _records = <String, _Record>{};
  // metadata
  final _epoch = <String, int>{};
  final _floor = <String, int>{}; // highest version provisioned or deleted
  final _denyUpTo = <String, int>{}; // versions at or below are denied
  final _snap =
      <String, (int, int, String)>{}; // owner -> (epoch, revision, identity)
  final _minAccept = <String, int>{}; // authoritative listed version
  final _disabled = <String>{};
  final _pending = <String>{}; // entry keys with a physical delete pending

  static String _k(String o, String e) => '$o\u0000$e';

  void loseKey() => _key = null;

  void corrupt(String owner, String entry) =>
      _records[_k(owner, entry)]!.seed[0] ^= 1;

  void moveRecord(String owner, String from, String to) {
    _records[_k(owner, to)] = _records.remove(_k(owner, from))!;
  }

  void rewritePeriod(String owner, String entry, int period) {
    final r = _records[_k(owner, entry)]!;
    _records[_k(owner, entry)] = _Record(
      r.version,
      r.algorithm,
      r.digits,
      period,
      r.epoch,
      r.seed,
      r.tag,
    );
  }

  void rewriteEpoch(String owner, String entry, int epoch) {
    final r = _records[_k(owner, entry)]!;
    _records[_k(owner, entry)] = _Record(
      r.version,
      r.algorithm,
      r.digits,
      r.period,
      epoch,
      r.seed,
      r.tag,
    );
  }

  /// Physically present entries (including ones logically denied and pending).
  List<String> entries(String owner) => [
    for (final k in _records.keys)
      if (k.startsWith('$owner\u0000')) k.split('\u0000')[1],
  ];

  int? versionOf(String owner, String entry) =>
      _records[_k(owner, entry)]?.version;

  void _meta() {
    if (metadataDown) {
      throw const CustodyException(CustodyError.metadataUnavailable);
    }
  }

  /// Persists a higher current epoch: older-epoch records are denied by epoch
  /// and queued for purge; epoch-scoped version state restarts.
  void _advance(String o, int epoch) {
    if (epoch <= (_epoch[o] ?? 0)) return;
    _epoch[o] = epoch;
    _floor.removeWhere((k, _) => k.startsWith('$o\u0000'));
    _denyUpTo.removeWhere((k, _) => k.startsWith('$o\u0000'));
    _minAccept.removeWhere((k, _) => k.startsWith('$o\u0000'));
    for (final k in [
      for (final e in _records.entries)
        if (e.key.startsWith('$o\u0000') && e.value.epoch < epoch) e.key,
    ]) {
      if (!_tryRemove(k)) _pending.add(k);
    }
  }

  bool get _storeDown => unavailable || locked;

  void _gate() {
    if (unavailable) throw const CustodyException(CustodyError.unavailable);
    if (locked) throw const CustodyException(CustodyError.locked);
    if (_key == null) throw const CustodyException(CustodyError.missingKey);
  }

  bool _denied(String o, _Record r, String e) =>
      r.epoch < (_epoch[o] ?? 0) || r.version <= (_denyUpTo[_k(o, e)] ?? 0);

  List<int> _tag(String o, String e, _Record r, [Uint8List? seed]) {
    final aad = custodyAad(
      ownerId: o,
      entryId: e,
      seedVersion: r.version,
      algorithm: r.algorithm,
      digits: r.digits,
      period: r.period,
      epoch: r.epoch,
    );
    return Hmac(sha256, _key!).convert([...aad, ...(seed ?? r.seed)]).bytes;
  }

  bool _tryRemove(String k) {
    if (_storeDown) return false;
    _records.remove(k);
    _pending.remove(k);
    return true;
  }

  void _deny(String o, String e, int version) {
    final k = _k(o, e);
    if (version > (_denyUpTo[k] ?? 0)) _denyUpTo[k] = version;
    if (version > (_floor[k] ?? 0)) _floor[k] = version;
  }

  @override
  Future<CustodyOwnerState> readOwnerState(String ownerId) async {
    if (!validCustodyId(ownerId)) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    if (metadataDown) {
      throw const CustodyException(CustodyError.metadataUnavailable);
    }
    return CustodyOwnerState(
      epoch: _epoch[ownerId] ?? 0,
      enabled: !_disabled.contains(ownerId),
    );
  }

  @override
  Future<CustodyCapability> capability() async => unavailable
      ? CustodyCapability(CustodyProtection.unavailable, unavailableReason)
      : CustodyCapability(reportedProtection, null);

  @override
  Future<void> provision({
    required String ownerId,
    required String entryId,
    required int seedVersion,
    required OtpAlgorithm algorithm,
    required int digits,
    required int period,
    required Uint8List seed,
    required int epoch,
  }) async {
    validateCustodyInput(
      ownerId: ownerId,
      entryId: entryId,
      seedVersion: seedVersion,
      digits: digits,
      period: period,
      seed: seed,
      epoch: epoch,
    );
    _meta();
    if (_disabled.contains(ownerId)) {
      throw const CustodyException(CustodyError.disabled);
    }
    if (epoch < (_epoch[ownerId] ?? 0)) {
      throw const CustodyException(CustodyError.staleEpoch);
    }
    final k = _k(ownerId, entryId);
    if (epoch > (_epoch[ownerId] ?? 0)) {
      // Only local lifecycle transitions advance the epoch, never a response.
      throw const CustodyException(CustodyError.epochMismatch);
    }
    if (seedVersion <= (_floor[k] ?? 0) || seedVersion < (_minAccept[k] ?? 0)) {
      throw const CustodyException(CustodyError.versionConflict);
    }
    final old = _records[k];
    if (old != null &&
        old.epoch >= (_epoch[ownerId] ?? 0) &&
        seedVersion <= old.version) {
      throw const CustodyException(CustodyError.versionConflict);
    }
    _gate();
    final copy = Uint8List.fromList(seed);
    final r = _Record(
      seedVersion,
      algorithm,
      digits,
      period,
      epoch,
      copy,
      const [],
    );
    _records[k] = _Record(
      seedVersion,
      algorithm,
      digits,
      period,
      epoch,
      copy,
      _tag(ownerId, entryId, r),
    );
    _pending.remove(k);
    _floor[k] = seedVersion;
  }

  @override
  Future<String> generate({
    required String ownerId,
    required String entryId,
    required int seedVersion,
    required int unixSeconds,
  }) async {
    if (!validCustodyId(ownerId) ||
        !validCustodyId(entryId) ||
        seedVersion < 1 ||
        seedVersion > custodyMaxSafeInt) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    _meta();
    final r = _records[_k(ownerId, entryId)];
    if (r == null) throw const CustodyException(CustodyError.notFound);
    // Logical deny first: it needs no unlocked store and no key.
    if (_denied(ownerId, r, entryId)) {
      throw const CustodyException(CustodyError.denied);
    }
    _gate();
    if (!_same(_tag(ownerId, entryId, r), r.tag)) {
      throw const CustodyException(CustodyError.tamper);
    }
    if (r.version != seedVersion) {
      throw const CustodyException(CustodyError.versionConflict);
    }
    final result = computeTotp(
      seed: r.seed,
      algorithm: r.algorithm,
      digits: r.digits,
      period: r.period,
      unixSeconds: unixSeconds,
    );
    await afterGenerate?.call();
    return result;
  }

  @override
  Future<void> delete(
    String ownerId,
    String entryId, {
    required int seedVersion,
  }) async {
    if (!validCustodyId(ownerId) ||
        !validCustodyId(entryId) ||
        seedVersion < 1 ||
        seedVersion > custodyMaxSafeInt) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    _meta();
    final k = _k(ownerId, entryId);
    final r = _records[k];
    final upTo = seedVersion;
    _deny(ownerId, entryId, upTo);
    if (r != null && r.version <= upTo) {
      if (!_tryRemove(k)) _pending.add(k);
    }
  }

  @override
  Future<ClearOwnerResult> clearOwner(
    String ownerId, {
    required int epoch,
  }) async {
    if (!validCustodyId(ownerId) || epoch < 0 || epoch >= custodyMaxSafeInt) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    _meta();
    if (epoch > (_epoch[ownerId] ?? 0)) {
      throw const CustodyException(CustodyError.epochMismatch);
    }
    final next = epoch + 1;
    if (next > (_epoch[ownerId] ?? 0)) {
      _disabled.add(ownerId);
      _advance(ownerId, next);
    }
    // Only records within the requested epoch; never a newer one.
    for (final k in [
      for (final e in _records.entries)
        if (e.key.startsWith('$ownerId\u0000') && e.value.epoch <= epoch) e.key,
    ]) {
      if (!_tryRemove(k)) _pending.add(k);
    }
    return ClearOwnerResult(
      purged: !_records.entries.any(
        (e) => e.key.startsWith('$ownerId\u0000') && e.value.epoch <= epoch,
      ),
    );
  }

  @override
  Future<PurgeOwnerResult> purgeOwner(
    String ownerId, {
    required int epoch,
  }) async {
    if (!validCustodyId(ownerId) || epoch < 0 || epoch >= custodyMaxSafeInt) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    _meta();
    if (epoch > (_epoch[ownerId] ?? 0)) {
      throw const CustodyException(CustodyError.epochMismatch);
    }
    if (epoch + 1 > (_epoch[ownerId] ?? 0)) _advance(ownerId, epoch + 1);
    for (final k in [
      for (final e in _records.entries)
        if (e.key.startsWith('$ownerId\u0000') && e.value.epoch <= epoch) e.key,
    ]) {
      if (!_tryRemove(k)) _pending.add(k);
    }
    return PurgeOwnerResult(
      purged: !_pending.any((k) => k.startsWith('$ownerId\u0000')),
      epoch: _epoch[ownerId] ?? 0,
    );
  }

  @override
  Future<CustodyCatalog> readCatalog(String ownerId) async {
    final state = await readOwnerState(ownerId);
    return CustodyCatalog(
      epoch: state.epoch,
      enabled: state.enabled,
      entries: [
        if (state.enabled)
          for (final e in _records.entries)
            if (e.key.startsWith('$ownerId\u0000') &&
                !_pending.contains(e.key) &&
                !_denied(ownerId, e.value, e.key.split('\u0000')[1]))
              CustodyCatalogEntry(
                entryId: e.key.split('\u0000')[1],
                seedVersion: e.value.version,
                epoch: e.value.epoch,
                algorithm: e.value.algorithm,
                digits: e.value.digits,
                period: e.value.period,
                protection: 'software',
                floor: _floor[e.key] ?? 0,
                minAcceptedVersion: _minAccept[e.key] ?? 0,
              ),
      ],
      pendingPurge: [
        for (final k in _pending)
          if (k.startsWith('$ownerId\u0000')) k.split('\u0000')[1],
      ],
    );
  }

  @override
  Future<void> enableOwner(String ownerId, {required int epoch}) async {
    if (!validCustodyId(ownerId) || epoch < 0 || epoch >= custodyMaxSafeInt) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    _meta();
    if (epoch < (_epoch[ownerId] ?? 0)) {
      throw const CustodyException(CustodyError.staleEpoch);
    }
    _advance(ownerId, epoch);
    _disabled.remove(ownerId);
  }

  @override
  Future<List<String>> purgePending() async {
    for (final k in _pending.toList()) {
      _tryRemove(k);
    }
    return [for (final k in _pending) k.replaceFirst('\u0000', '/')]..sort();
  }

  @override
  Future<ReconcileResult> reconcile(String ownerId, CustodySnapshot s) async {
    _validate(ownerId, s);
    _meta();
    if (_disabled.contains(ownerId)) {
      throw const CustodyException(CustodyError.disabled);
    }
    if (s.epoch < (_epoch[ownerId] ?? 0)) {
      throw const CustodyException(CustodyError.staleEpoch);
    }
    if (s.epoch > (_epoch[ownerId] ?? 0)) {
      throw const CustodyException(CustodyError.epochMismatch);
    }
    final last = _snap[ownerId];
    final identity = _identity(s);
    final replay =
        last != null &&
        s.epoch == last.$1 &&
        s.revision == last.$2 &&
        last.$3 == identity;
    if (last != null &&
        !replay &&
        (s.epoch < last.$1 || (s.epoch == last.$1 && s.revision <= last.$2))) {
      throw const CustodyException(CustodyError.staleSnapshot);
    }
    _snap[ownerId] = (s.epoch, s.revision, identity);
    // Every listed version is the minimum the device will now accept.
    for (final v in s.versions.entries) {
      final k = _k(ownerId, v.key);
      if (v.value > (_minAccept[k] ?? 0)) _minAccept[k] = v.value;
    }
    final removed = <String>[];
    final superseded = <String>[];
    for (final e in entries(ownerId)) {
      final r = _records[_k(ownerId, e)]!;
      if (r.epoch < (_epoch[ownerId] ?? 0)) continue; // already denied
      final t = s.tombstones[e];
      final gone =
          (t != null && r.version <= t) ||
          (s.complete &&
              !s.versions.containsKey(e) &&
              !s.preserve.contains(e) &&
              t == null);
      final listed = s.versions[e];
      if (gone) {
        _deny(ownerId, e, r.version);
        removed.add(e);
        if (!_tryRemove(_k(ownerId, e))) _pending.add(_k(ownerId, e));
      } else if (listed != null && listed > r.version) {
        // Authoritative rotation: the old version is revoked right now.
        _deny(ownerId, e, r.version);
        superseded.add(e);
        if (!_tryRemove(_k(ownerId, e))) _pending.add(_k(ownerId, e));
      }
    }
    // A tombstone also blocks later provisions at or below it, with no record.
    for (final t in s.tombstones.entries) {
      _deny(ownerId, t.key, t.value);
    }
    final need = <String>[];
    for (final v in s.versions.entries) {
      final k = _k(ownerId, v.key);
      final have = [
        if (_records[k] != null && !_denied(ownerId, _records[k]!, v.key))
          _records[k]!.version,
        _floor[k] ?? 0,
      ].fold<int>(0, (a, b) => a > b ? a : b);
      if (v.value > have) need.add(v.key);
    }
    return ReconcileResult(
      removed: removed,
      superseded: superseded..sort(),
      needsProvision: need,
      pendingPurge: [
        for (final k in _pending)
          if (k.startsWith('$ownerId\u0000')) k.split('\u0000')[1],
      ]..sort(),
    );
  }

  static String _identity(CustodySnapshot s) {
    String m(Map<String, int> x) =>
        (x.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
            .map((e) => '${e.key}=${e.value}')
            .join(',');
    return '${s.epoch}|${s.revision}|${s.complete}|${m(s.versions)}|${m(s.tombstones)}|${(s.preserve.toList()..sort()).join(',')}';
  }

  void _validate(String owner, CustodySnapshot s) {
    CustodyException bad() =>
        const CustodyException(CustodyError.invalidSnapshot);
    if (!validCustodyId(owner)) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    if (s.epoch < 0 ||
        s.epoch >= custodyMaxSafeInt ||
        s.revision < 1 ||
        s.revision > custodyMaxSafeInt ||
        s.versions.length > 5000 ||
        s.tombstones.length > 5000) {
      throw bad();
    }
    for (final m in [s.versions, s.tombstones]) {
      for (final e in m.entries) {
        if (!validCustodyId(e.key) ||
            e.value < 1 ||
            e.value > custodyMaxSafeInt) {
          throw bad();
        }
      }
    }
    for (final e in s.versions.entries) {
      final t = s.tombstones[e.key];
      if (t != null && e.value <= t) throw bad();
    }
    if (s.preserve.length > 5000 ||
        s.preserve.any(
          (e) => !validCustodyId(e) || s.versions.containsKey(e),
        )) {
      throw bad();
    }
  }

  static bool _same(List<int> a, List<int> b) {
    var d = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}

final class _Record {
  _Record(
    this.version,
    this.algorithm,
    this.digits,
    this.period,
    this.epoch,
    this.seed,
    this.tag,
  );
  final int version, digits, period, epoch;
  final OtpAlgorithm algorithm;
  final Uint8List seed;
  final List<int> tag;
}
