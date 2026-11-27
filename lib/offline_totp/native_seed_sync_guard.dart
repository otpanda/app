import 'native_seed_custody.dart';

/// Why the guard refused. Nothing changes on a refusal, except where noted.
enum GuardError {
  /// No complete authenticated snapshot has been applied since start, restart,
  /// enable, disable or owner switch. Fetch one first.
  notReady,

  /// The owner is disabled (opted out or signed out).
  disabled,

  /// Snapshot, ticket or request belongs to another owner.
  ownerMismatch,

  /// Snapshot, ticket or request belongs to another device.
  deviceMismatch,

  /// Carries an epoch other than the device's current local epoch. A server
  /// message never advances the epoch.
  epochMismatch,

  /// A snapshot not newer (by revision) than the last applied one.
  staleSnapshot,

  /// A snapshot with invalid or contradictory fields; nothing applied.
  invalidSnapshot,

  /// The entry is not authorized by the current snapshot at that version.
  unauthorized,

  /// The ticket is unknown, already used, or issued under an older state
  /// generation (snapshot, disable, enable, owner switch, restart, rotation).
  staleTicket,

  /// Bad identifier or number.
  invalidInput,
}

final class GuardException implements Exception {
  const GuardException(this.error);
  final GuardError error;
  @override
  String toString() => 'GuardException($error)';
}

/// An authenticated snapshot as the sync layer receives it. The caller
/// authenticates it before handing it over; the guard does not.
final class GuardSnapshot {
  const GuardSnapshot({
    required this.ownerId,
    required this.deviceId,
    required this.epoch,
    required this.revision,
    required this.complete,
    required this.versions,
    this.tombstones = const {},
  });
  final String ownerId, deviceId;
  final int epoch, revision;

  /// True only when [versions] lists every authorized entry for the owner.
  final bool complete;
  final Map<String, int> versions;
  final Map<String, int> tombstones;
}

/// Permission to hand one seed response to custody. Single use. Holds no seed.
final class ProvisionTicket {
  const ProvisionTicket._(
    this.id,
    this.ownerId,
    this.deviceId,
    this.epoch,
    this.generation,
    this.entryId,
    this.seedVersion,
  );
  final int id, epoch, generation, seedVersion;
  final String ownerId, deviceId, entryId;
}

/// Binds seed provisioning to the current authorization state, separately from
/// the custody store: a seed response may only reach `custody.provision` if
/// [consume] succeeds. State is in memory and NOT restored after a restart:
/// [restart] (or a real process restart) leaves the guard not ready until a
/// fresh complete authenticated snapshot is applied.
///
/// Any change of state bumps a generation that invalidates every ticket
/// issued before it. That is deliberately coarse: a caller whose ticket went
/// stale asks for the seed again under the new state.
///
/// The integration must run [consume] and `custody.provision` as one
/// serialized step, so a lifecycle transition cannot slip between them. The
/// caller zeroes a rejected response's seed. This class never sees a seed.
final class NativeSeedSyncGuard {
  NativeSeedSyncGuard({
    required String ownerId,
    required String deviceId,
    required int epoch,
  }) : _owner = _id(ownerId),
       _device = _id(deviceId),
       _epoch = _epochOk(epoch);

  String _owner, _device;
  int _epoch;
  bool _enabled = true;
  bool _ready = false;
  int _generation = 0;
  int? _lastRevision;
  int _nextId = 1;
  final _authorized = <String, int>{};
  final _tombstones = <String, int>{};
  final _live = <int, ProvisionTicket>{};

  static String _id(String s) {
    if (!validCustodyId(s)) throw const GuardException(GuardError.invalidInput);
    return s;
  }

  static int _epochOk(int e) {
    if (e < 0 || e >= custodyMaxSafeInt) {
      throw const GuardException(GuardError.invalidInput);
    }
    return e;
  }

  bool get ready => _ready && _enabled;
  bool get enabled => _enabled;
  int get epoch => _epoch;
  int get generation => _generation;

  /// Version the current snapshot authorizes for [entryId], or null.
  int? authorizedVersion(String entryId) => _authorized[entryId];

  void _reset({required bool keepRevision}) {
    _generation++;
    _ready = false;
    _authorized.clear();
    _tombstones.clear();
    _live.clear();
    if (!keepRevision) _lastRevision = null;
  }

  /// Process restart without durable guard state: nothing is trusted until a
  /// fresh complete snapshot arrives.
  void restart() => _reset(keepRevision: false);

  /// Opt-out or sign-out. Invalidates everything in flight.
  void disable() {
    _enabled = false;
    _reset(keepRevision: false);
  }

  /// Explicit local re-enable; [epoch] must be at least the current one.
  void enable(int epoch) {
    _epochOk(epoch);
    if (epoch < _epoch) throw const GuardException(GuardError.epochMismatch);
    _epoch = epoch;
    _enabled = true;
    _reset(keepRevision: false);
  }

  /// Account switch on this device. Starts not ready, enabled.
  void switchOwner({
    required String ownerId,
    required String deviceId,
    required int epoch,
  }) {
    final o = _id(ownerId), d = _id(deviceId), e = _epochOk(epoch);
    _owner = o;
    _device = d;
    _epoch = e;
    _enabled = true;
    _reset(keepRevision: false);
  }

  void _validate(GuardSnapshot s) {
    GuardException bad() => const GuardException(GuardError.invalidSnapshot);
    if (s.revision < 1 ||
        s.revision > custodyMaxSafeInt ||
        s.epoch < 0 ||
        s.epoch >= custodyMaxSafeInt ||
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
  }

  /// Applies an authenticated snapshot. A complete one replaces the authorized
  /// set exactly (omitted entries lose authorization). A partial one updates
  /// and tombstones the entries it names and never authorizes any other entry;
  /// it also cannot make the guard ready. Every applied snapshot invalidates
  /// all outstanding tickets.
  void applySnapshot(GuardSnapshot s) {
    if (!validCustodyId(s.ownerId) || !validCustodyId(s.deviceId)) {
      throw const GuardException(GuardError.invalidSnapshot);
    }
    if (s.ownerId != _owner) {
      throw const GuardException(GuardError.ownerMismatch);
    }
    if (s.deviceId != _device) {
      throw const GuardException(GuardError.deviceMismatch);
    }
    if (!_enabled) throw const GuardException(GuardError.disabled);
    _validate(s);
    if (s.epoch != _epoch) throw const GuardException(GuardError.epochMismatch);
    final last = _lastRevision;
    if (last != null && s.revision <= last) {
      throw const GuardException(GuardError.staleSnapshot);
    }
    _generation++;
    _live.clear();
    _lastRevision = s.revision;
    for (final t in s.tombstones.entries) {
      if (t.value > (_tombstones[t.key] ?? 0)) _tombstones[t.key] = t.value;
      final a = _authorized[t.key];
      if (a != null && a <= t.value) _authorized.remove(t.key);
    }
    if (s.complete) {
      _authorized
        ..clear()
        ..addAll(s.versions);
      _ready = true;
    } else {
      for (final v in s.versions.entries) {
        _authorized[v.key] = v.value;
      }
    }
  }

  /// Issues a ticket to request or accept the seed for [entryId] at
  /// [seedVersion]. Only the version the current snapshot authorizes.
  ProvisionTicket issue({
    required String ownerId,
    required String deviceId,
    required String entryId,
    required int seedVersion,
  }) {
    if (!validCustodyId(entryId) ||
        seedVersion < 1 ||
        seedVersion > custodyMaxSafeInt) {
      throw const GuardException(GuardError.invalidInput);
    }
    if (ownerId != _owner) throw const GuardException(GuardError.ownerMismatch);
    if (deviceId != _device) {
      throw const GuardException(GuardError.deviceMismatch);
    }
    if (!_enabled) throw const GuardException(GuardError.disabled);
    if (!_ready) throw const GuardException(GuardError.notReady);
    if (_authorized[entryId] != seedVersion ||
        seedVersion <= (_tombstones[entryId] ?? 0)) {
      throw const GuardException(GuardError.unauthorized);
    }
    final t = ProvisionTicket._(
      _nextId++,
      _owner,
      _device,
      _epoch,
      _generation,
      entryId,
      seedVersion,
    );
    _live[t.id] = t;
    return t;
  }

  /// Checks a ticket that came back with a seed response and uses it up. Throws
  /// on any mismatch; the caller then must not call custody and must zero the
  /// seed. [ownerId], [deviceId], [epoch], [entryId] and [seedVersion] are what
  /// the RESPONSE claims; they must equal the ticket and the current state.
  void consume(
    ProvisionTicket ticket, {
    required String ownerId,
    required String deviceId,
    required int epoch,
    required String entryId,
    required int seedVersion,
  }) {
    final known = _live[ticket.id];
    if (known == null || !identical(known, ticket)) {
      throw const GuardException(GuardError.staleTicket);
    }
    if (ownerId != _owner || ticket.ownerId != _owner) {
      throw const GuardException(GuardError.ownerMismatch);
    }
    if (deviceId != _device || ticket.deviceId != _device) {
      throw const GuardException(GuardError.deviceMismatch);
    }
    if (epoch != _epoch || ticket.epoch != _epoch) {
      throw const GuardException(GuardError.epochMismatch);
    }
    if (!_enabled) throw const GuardException(GuardError.disabled);
    if (!_ready) throw const GuardException(GuardError.notReady);
    if (ticket.generation != _generation) {
      throw const GuardException(GuardError.staleTicket);
    }
    if (entryId != ticket.entryId || seedVersion != ticket.seedVersion) {
      throw const GuardException(GuardError.unauthorized);
    }
    if (_authorized[entryId] != seedVersion ||
        seedVersion <= (_tombstones[entryId] ?? 0)) {
      throw const GuardException(GuardError.unauthorized);
    }
    _live.remove(ticket.id);
  }
}
