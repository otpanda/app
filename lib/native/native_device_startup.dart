import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'native_device_proof.dart';
import 'native_device_routes.dart';
import 'native_enroll_recovery.dart';
import 'native_auth.dart' show NativeSession;

/// Build-time switch for every enrolled-device startup step. Off by default:
/// with it off nothing here runs, no request is made, no state is read.
const bool nativeAuthEnabled = bool.fromEnvironment('NATIVE_AUTH_ENABLED');

/// Device-key routes over the bearer client (the signed-in owner session).
/// The request goes out as JSON with exactly application/json (see the
/// adapter). Non-JSON or non-object replies are a null body.
DevicePost bearerDevicePost(BearerRequest request, String Function() bearer) =>
    (path, body) async {
      final r = await request(
        'POST',
        path,
        // Always a JSON object, even {}: the server rejects a missing body.
        body: jsonEncode(body),
        bearer: bearer(),
      );
      Map<String, dynamic>? parsed;
      try {
        final j = jsonDecode(r.body);
        if (j is Map<String, dynamic>) parsed = j;
      } catch (_) {}
      return (status: r.status, body: parsed);
    };

/// Once per signed-in session: reconcile an interrupted enrollment from the
/// stored record. Returns null when disabled, signed out, or the owner cannot
/// be read (nothing is changed in any of those cases). The enroll grant is
/// memory only, so after a restart there is none: finish is never replayed
/// here, recovery goes to status and adopt. Needs-adopt, revoked and waiting
/// are returned for the UI; nothing is deleted and nothing is signed.
Future<RecoveryResult?> runNativeStartupRecovery({
  required NativeSession? session,
  required BearerRequest request,
  required DeviceProofSource source,
  required PendingEnrollStore store,
  bool enabled = nativeAuthEnabled,
  int Function()? now,
}) async {
  if (!enabled) return null;
  final s = session;
  if (s == null) return null;
  String? ownerId;
  try {
    final r = await request('GET', '/v1/manage/session', bearer: s.access);
    if (r.status == 200) {
      final j = jsonDecode(r.body);
      final o = j is Map ? j['ownerId'] : null;
      if (o is String && o.isNotEmpty) ownerId = o;
    }
  } catch (_) {}
  if (ownerId == null) return null;
  return recoverEnrollment(
    store: store,
    source: source,
    enrollRoutes: null,
    statusRoutes: DeviceStatusRoutes(bearerDevicePost(request, () => s.access)),
    ownerId: ownerId,
    sessionDeviceId: s.deviceId,
    onEnrolled: (_) async =>
        throw StateError('no enrollment confirmation without a live finish'),
    now: now,
  );
}

/// Serializes pending-store work: whole recovery runs and single store ops
/// queue behind each other, so two writers never interleave.
class AsyncLock {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() f) {
    final done = Completer<void>();
    final prev = _tail;
    _tail = done.future;
    return prev.then((_) => f()).whenComplete(done.complete);
  }
}

/// The enroll pending store with each operation under [lock]. Use this for
/// every enrollment write; recovery holds the same lock for its whole run and
/// uses the raw store inside it.
class LockedPendingStore implements PendingEnrollStore {
  LockedPendingStore(this._inner, this._lock);
  final PendingEnrollStore _inner;
  final AsyncLock _lock;
  AsyncLock get lock => _lock;
  @override
  Future<PendingRead> read() => _lock.run(_inner.read);
  @override
  Future<void> write(PendingRecord r) => _lock.run(() => _inner.write(r));
  @override
  Future<void> clear() => _lock.run(_inner.clear);
}

/// A recovery outcome tied to the owner and session it was read for.
class BoundRecovery {
  const BoundRecovery(this.ownerId, this.deviceId, this.result, this.access);
  final String ownerId, deviceId;
  final RecoveryResult result;

  /// The access token the owner was last verified with. A renewed token means
  /// the owner is read again before the result is reused.
  final String access;
}

/// Runs startup recovery per signed-in session, not once per process.
///  - The result is bound to ownerId + deviceId; sign-out or another device
///    clears it; a renewed access token re-verifies the owner before reuse and
///    drops the result if the owner changed.
///  - A late async result from an older session is discarded.
///  - Attempts are rate limited no matter how often the controller notifies:
///    failures back off 15 s, 30 s, 60 s ... up to 10 min and respect
///    Retry-After; `waiting` waits for its waitUntilMs. There is no polling of
///    a healthy state: settled outcomes make no request.
///  - [store] must be the RAW store. Recovery holds [lock] for its whole run
///    and every other writer goes through LockedPendingStore(raw, lock).
class NativeStartupRecovery extends ChangeNotifier {
  NativeStartupRecovery({
    required this.request,
    required this.source,
    required PendingEnrollStore store,
    AsyncLock? lock,
    this.enabled = nativeAuthEnabled,
    this.now,
  }) : store = _raw(store),
       lock = lock ?? AsyncLock();
  final BearerRequest request;
  final DeviceProofSource source;
  final PendingEnrollStore store;
  final AsyncLock lock;
  final bool enabled;
  final int Function()? now;

  static PendingEnrollStore _raw(PendingEnrollStore s) {
    if (s is LockedPendingStore) {
      throw ArgumentError('startup recovery needs the raw store (deadlock)');
    }
    return s;
  }

  static const _gapBase = 15000, _gapMax = 600000;

  BoundRecovery? _current;
  int _epoch = 0, _failures = 0, _nextAllowed = 0;
  bool _running = false;
  String? _runDevice;

  BoundRecovery? get current => _current;
  int _clock() => (now ?? () => DateTime.now().millisecondsSinceEpoch)();

  static bool _settled(RecoveryOutcome o) =>
      o != RecoveryOutcome.unknown && o != RecoveryOutcome.waiting;

  void _backoff({int? retryAfterSeconds}) {
    final gap = (_gapBase * (1 << (_failures > 5 ? 5 : _failures))).clamp(
      _gapBase,
      _gapMax,
    );
    _failures++;
    final ra = (retryAfterSeconds ?? 0) * 1000;
    _nextAllowed = _clock() + (ra > gap ? ra : gap);
  }

  /// Forget the settled result and its retry floor, e.g. after adopt, enroll
  /// or add succeeded, so the next signed-in notification reads fresh state
  /// instead of showing a stale needsAdopt.
  void invalidate() {
    _epoch++;
    _running = false;
    _failures = 0;
    _nextAllowed = 0;
    if (_current != null) {
      _current = null;
      notifyListeners();
    }
  }

  /// Call with the signed-in session, or null on sign-out / sign-in required.
  /// Do not call for a transient offline state. Safe to call on every
  /// controller notification.
  Future<void> sessionChanged(NativeSession? s) async {
    if (!enabled) return;
    if (s == null) {
      _epoch++;
      _running = false;
      _failures = 0;
      _nextAllowed = 0;
      if (_current != null) {
        _current = null;
        notifyListeners();
      }
      return;
    }
    if (_current != null && _current!.deviceId != s.deviceId) {
      _epoch++;
      _current = null;
      _running = false;
      _failures = 0;
      _nextAllowed = 0;
      notifyListeners();
    }
    if (_running && _runDevice == s.deviceId) return;
    final cur = _current;
    final reuse =
        cur != null &&
        cur.deviceId == s.deviceId &&
        _settled(cur.result.outcome);
    if (reuse && cur.access == s.access) return;
    if (_clock() < _nextAllowed) return; // rate limited, no request
    final epoch = ++_epoch;
    _running = true;
    _runDevice = s.deviceId;
    RecoveryResult? r;
    String? owner;
    int? retryAfter;
    try {
      final o = await _ownerOf(s);
      owner = o.owner;
      retryAfter = o.retryAfter;
      if (epoch != _epoch) return;
      if (owner != null && reuse) {
        if (owner == cur.ownerId) {
          _running = false;
          _failures = 0;
          _current = BoundRecovery(owner, s.deviceId, cur.result, s.access);
          return;
        }
        _current = null; // another owner: never reuse
        notifyListeners();
      }
      if (owner != null) {
        r = await lock.run(
          () => recoverEnrollment(
            store: store,
            source: source,
            enrollRoutes: null,
            statusRoutes: DeviceStatusRoutes(
              bearerDevicePost(request, () => s.access),
            ),
            ownerId: owner!,
            sessionDeviceId: s.deviceId,
            onEnrolled: (_) async => throw StateError(
              'no enrollment confirmation without a live finish',
            ),
            now: now,
          ),
        );
      }
    } catch (_) {
      r = null;
    }
    if (epoch != _epoch) return; // late result for an older session
    _running = false;
    if (r != null && owner != null) {
      if (_settled(r.outcome)) {
        _failures = 0;
        _nextAllowed = 0;
      } else if (r.outcome == RecoveryOutcome.waiting) {
        _nextAllowed = r.waitUntilMs ?? _clock() + 60000;
      } else {
        _backoff();
      }
      _current = BoundRecovery(owner, s.deviceId, r, s.access);
      notifyListeners();
    } else {
      _backoff(retryAfterSeconds: retryAfter);
    }
  }

  Future<({String? owner, int? retryAfter})> _ownerOf(NativeSession s) async {
    try {
      final r = await request('GET', '/v1/manage/session', bearer: s.access);
      if (r.status != 200)
        return (owner: null, retryAfter: r.retryAfterSeconds);
      final j = jsonDecode(r.body);
      final o = j is Map ? j['ownerId'] : null;
      return (owner: o is String && o.isNotEmpty ? o : null, retryAfter: null);
    } catch (_) {
      return (owner: null, retryAfter: null);
    }
  }
}
