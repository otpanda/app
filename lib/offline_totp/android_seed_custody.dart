
import 'package:flutter/services.dart';

import 'native_seed_custody.dart';
import 'otp_account.dart';

/// Android native custody channel. No method returns seed bytes.
final class AndroidSeedCustody implements NativeSeedCustody {
  AndroidSeedCustody({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('app.otpanda/seed-custody');

  final MethodChannel _channel;

  static const _errors = <String, CustodyError>{
    'UNAVAILABLE': CustodyError.unavailable,
    'LOCKED': CustodyError.locked,
    'MISSING_KEY': CustodyError.missingKey,
    'NOT_FOUND': CustodyError.notFound,
    'TAMPER': CustodyError.tamper,
    'VERSION_CONFLICT': CustodyError.versionConflict,
    'STALE_EPOCH': CustodyError.staleEpoch,
    'EPOCH_MISMATCH': CustodyError.epochMismatch,
    'DENIED': CustodyError.denied,
    'DISABLED': CustodyError.disabled,
    'STALE_SNAPSHOT': CustodyError.staleSnapshot,
    'INVALID_SNAPSHOT': CustodyError.invalidSnapshot,
    'INVALID_INPUT': CustodyError.invalidInput,
    'METADATA_UNAVAILABLE': CustodyError.metadataUnavailable,
  };

  Never _invalid() => throw const CustodyException(CustodyError.unavailable);

  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      throw CustodyException(_errors[e.code] ?? CustodyError.unavailable);
    } on MissingPluginException {
      throw const CustodyException(CustodyError.unavailable);
    }
  }

  Map<Object?, Object?> _map(Object? v, Set<String> keys) {
    if (v is! Map ||
        v.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(v.keys.toSet()).isNotEmpty) {
      _invalid();
    }
    return v;
  }

  List<String> _ids(Object? v) {
    if (v is! List || v.any((e) => e is! String || !validCustodyId(e))) {
      _invalid();
    }
    return List<String>.from(v);
  }

  @override
  Future<CustodyCapability> capability() async {
    final v = _map(await _call('capability'), {'protection', 'reason'});
    final p = switch (v['protection']) {
      'HARDWARE_HMAC' => CustodyProtection.hardwareHmac,
      'HARDWARE_WRAPPED' => CustodyProtection.hardwareWrapped,
      'OS_ENCRYPTED' => CustodyProtection.osEncrypted,
      'UNAVAILABLE' => CustodyProtection.unavailable,
      _ => _invalid(),
    };
    // Native diagnostic strings are not displayed or propagated.
    return CustodyCapability(
      p,
      p == CustodyProtection.unavailable ? 'Native custody unavailable.' : null,
    );
  }

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
    final copy = Uint8List.fromList(seed);
    try {
      validateCustodyInput(
        ownerId: ownerId,
        entryId: entryId,
        seedVersion: seedVersion,
        digits: digits,
        period: period,
        seed: copy,
        epoch: epoch,
      );
      if (await _call('provision', {
            'owner': ownerId,
            'entry': entryId,
            'seedVersion': seedVersion,
            'algorithm': algorithm.name,
            'digits': digits,
            'periodSeconds': period,
            'seed': copy,
            'epoch': epoch,
          }) !=
          null) {
        _invalid();
      }
    } finally {
      copy.fillRange(0, copy.length, 0);
    }
  }

  @override
  Future<String> generate({
    required String ownerId,
    required String entryId,
    required int seedVersion,
    required int unixSeconds,
  }) async {
    final v = await _call('generate', {
      'owner': ownerId,
      'entry': entryId,
      'seedVersion': seedVersion,
      'unixSeconds': unixSeconds,
    });
    if (v is! String || !RegExp(r'^\d{6,8}$').hasMatch(v)) _invalid();
    return v;
  }

  @override
  Future<void> delete(
    String ownerId,
    String entryId, {
    required int seedVersion,
  }) async {
    if (await _call('delete', {
          'owner': ownerId,
          'entry': entryId,
          'seedVersion': seedVersion,
        }) !=
        null) {
      _invalid();
    }
  }

  @override
  Future<ClearOwnerResult> clearOwner(
    String ownerId, {
    required int epoch,
  }) async {
    final v = _map(
      await _call('clearOwner', {'owner': ownerId, 'epoch': epoch}),
      {'denied', 'purged'},
    );
    if (v['denied'] != true || v['purged'] is! bool) _invalid();
    return ClearOwnerResult(purged: v['purged'] as bool);
  }

  @override
  Future<void> enableOwner(String ownerId, {required int epoch}) async {
    if (await _call('enableOwner', {'owner': ownerId, 'epoch': epoch}) != null) {
      _invalid();
    }
  }

  @override
  Future<List<String>> purgePending() async =>
      _ids(await _call('purgePending'));

  @override
  Future<ReconcileResult> reconcile(
    String ownerId,
    CustodySnapshot snapshot,
  ) async {
    final v = _map(
      await _call('reconcile', {
        'owner': ownerId,
        'snapshot': {
          'epoch': snapshot.epoch,
          'revision': snapshot.revision,
          'complete': snapshot.complete,
          'versions': snapshot.versions,
          'tombstones': snapshot.tombstones,
        },
      }),
      {'removed', 'superseded', 'needsProvision', 'pendingPurge'},
    );
    return ReconcileResult(
      removed: _ids(v['removed']),
      superseded: _ids(v['superseded']),
      needsProvision: _ids(v['needsProvision']),
      pendingPurge: _ids(v['pendingPurge']),
    );
  }
}
