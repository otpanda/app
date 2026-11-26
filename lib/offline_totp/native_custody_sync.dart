import 'dart:async';
import 'dart:typed_data';

import 'native_seed_custody.dart';
import 'native_seed_sync_guard.dart';
import 'otp_account.dart';

/// One queue for native custody and its in-memory authorization guard.
/// Network fetches happen outside this queue, between issue and accept.
/// Construct only after the owner/device/local epoch have been read durably.
final class NativeCustodySync {
  NativeCustodySync({
    required this._custody,
    required String ownerId,
    required String deviceId,
    required int epoch,
  }) : _owner = ownerId,
       _guard = NativeSeedSyncGuard(
         ownerId: ownerId,
         deviceId: deviceId,
         epoch: epoch,
       );

  /// Restart bootstrap reads only durable local preference. It never restores
  /// snapshot authorization, enables a disabled owner or changes the epoch.
  static Future<NativeCustodySync> open({
    required NativeSeedCustody custody,
    required String ownerId,
    required String deviceId,
  }) async {
    final state = await custody.readOwnerState(ownerId);
    final sync = NativeCustodySync(
      custody: custody,
      ownerId: ownerId,
      deviceId: deviceId,
      epoch: state.epoch,
    );
    if (!state.enabled) sync._guard.disable();
    return sync;
  }

  /// Shares the transition queue; the answer itself grants no seed access.
  Future<CustodyOwnerState> readOwnerState() =>
      _serial(() => _custody.readOwnerState(_owner));

  final NativeSeedCustody _custody;
  final NativeSeedSyncGuard _guard;
  String _owner;
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() run) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await run());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  Future<ReconcileResult> reconcile(GuardSnapshot snapshot) =>
      _serial(() async {
        _guard.applySnapshot(snapshot);
        try {
          return await _custody.reconcile(
            _owner,
            CustodySnapshot(
              epoch: snapshot.epoch,
              revision: snapshot.revision,
              complete: snapshot.complete,
              versions: snapshot.versions,
              tombstones: snapshot.tombstones,
            ),
          );
        } catch (_) {
          // No new ticket may be issued after a failed durable transition.
          _guard.restart();
          rethrow;
        }
      });

  Future<ProvisionTicket> issue({
    required String ownerId,
    required String deviceId,
    required String entryId,
    required int seedVersion,
  }) => _serial(
    () async => _guard.issue(
      ownerId: ownerId,
      deviceId: deviceId,
      entryId: entryId,
      seedVersion: seedVersion,
    ),
  );

  /// Takes ownership of [seed]. Zeroes it on success, rejection and failure.
  Future<void> accept(
    ProvisionTicket ticket, {
    required String ownerId,
    required String deviceId,
    required int epoch,
    required String entryId,
    required int seedVersion,
    required OtpAlgorithm algorithm,
    required int digits,
    required int period,
    required Uint8List seed,
  }) => _serial(() async {
    try {
      _guard.consume(
        ticket,
        ownerId: ownerId,
        deviceId: deviceId,
        epoch: epoch,
        entryId: entryId,
        seedVersion: seedVersion,
      );
      await _custody.provision(
        ownerId: ownerId,
        entryId: entryId,
        seedVersion: seedVersion,
        algorithm: algorithm,
        digits: digits,
        period: period,
        seed: seed,
        epoch: epoch,
      );
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  });

  Future<ClearOwnerResult> disable() => _serial(() async {
    _guard.disable();
    return _custody.clearOwner(_owner, epoch: _guard.epoch);
  });

  /// Caller supplies the current durable epoch after clear, never a server epoch.
  Future<void> enable(int localEpoch) => _serial(() async {
    await _custody.enableOwner(_owner, epoch: localEpoch);
    _guard.enable(localEpoch);
  });

  Future<void> switchOwner({
    required String ownerId,
    required String deviceId,
    required int localEpoch,
  }) => _serial(() async {
    // Invalidate old tickets even when durable cleanup fails.
    _guard.disable();
    await _custody.clearOwner(_owner, epoch: _guard.epoch);
    _guard.switchOwner(ownerId: ownerId, deviceId: deviceId, epoch: localEpoch);
    _owner = ownerId;
  });
}
