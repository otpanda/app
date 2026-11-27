import 'dart:async';

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

  /// A timed-out mutation may still complete natively. Callers must keep
  /// authorization invalidated and re-read durable truth before continuing.
  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel
          .invokeMethod<Object?>(method, args)
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const CustodyException(CustodyError.unavailable);
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
    if (v is! List ||
        v.length > 5000 ||
        v.toSet().length != v.length ||
        v.any((e) => e is! String || !validCustodyId(e))) {
      _invalid();
    }
    return List<String>.from(v);
  }

  @override
  Future<CustodyOwnerState> readOwnerState(String ownerId) async {
    if (!validCustodyId(ownerId)) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    final v = _map(await _call('readOwnerState', {'owner': ownerId}), {
      'epoch',
      'enabled',
    });
    final epoch = v['epoch'];
    if (epoch is! int ||
        epoch < 0 ||
        epoch >= custodyMaxSafeInt ||
        v['enabled'] is! bool) {
      _invalid();
    }
    return CustodyOwnerState(epoch: epoch, enabled: v['enabled'] as bool);
  }

  int _number(Object? v, {int min = 0, int max = custodyMaxSafeInt}) {
    if (v is! int || v < min || v > max) _invalid();
    return v;
  }

  @override
  Future<PurgeOwnerResult> purgeOwner(
    String ownerId, {
    required int epoch,
  }) async {
    if (!validCustodyId(ownerId) || epoch < 0 || epoch >= custodyMaxSafeInt) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    final v = _map(
      await _call('purgeOwner', {'owner': ownerId, 'epoch': epoch}),
      {'purged', 'epoch'},
    );
    if (v['purged'] is! bool) _invalid();
    final effective = _number(
      v['epoch'],
      min: epoch + 1,
      max: custodyMaxSafeInt - 1,
    );
    return PurgeOwnerResult(purged: v['purged'] as bool, epoch: effective);
  }

  @override
  Future<CustodyCatalog> readCatalog(String ownerId) async {
    if (!validCustodyId(ownerId)) {
      throw const CustodyException(CustodyError.invalidInput);
    }
    final v = _map(await _call('readCatalog', {'owner': ownerId}), {
      'epoch',
      'enabled',
      'entries',
      'pendingPurge',
    });
    final epoch = _number(v['epoch'], max: custodyMaxSafeInt - 1);
    if (v['enabled'] is! bool || v['entries'] is! List) _invalid();
    final entries = v['entries'] as List;
    if (entries.length > 5000 || v['enabled'] == false && entries.isNotEmpty) {
      _invalid();
    }
    final seen = <String>{};
    final result = <CustodyCatalogEntry>[];
    for (final value in entries) {
      final e = _map(value, {
        'entry',
        'seedVersion',
        'epoch',
        'algorithm',
        'digits',
        'periodSeconds',
        'protection',
        'floor',
        'minAcceptedVersion',
      });
      final id = e['entry'];
      final protection = e['protection'];
      if (id is! String ||
          !validCustodyId(id) ||
          !seen.add(id) ||
          protection is! String ||
          !RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(protection)) {
        _invalid();
      }
      final alg = switch (e['algorithm']) {
        'sha1' => OtpAlgorithm.sha1,
        'sha256' => OtpAlgorithm.sha256,
        'sha512' => OtpAlgorithm.sha512,
        _ => _invalid(),
      };
      final entryEpoch = _number(e['epoch'], max: custodyMaxSafeInt - 1);
      if (entryEpoch != epoch) _invalid();
      result.add(
        CustodyCatalogEntry(
          entryId: id,
          seedVersion: _number(e['seedVersion'], min: 1),
          epoch: entryEpoch,
          algorithm: alg,
          digits: _number(e['digits'], min: 6, max: 8),
          period: _number(e['periodSeconds'], min: 1, max: 86400),
          protection: protection,
          floor: _number(e['floor']),
          minAcceptedVersion: _number(e['minAcceptedVersion']),
        ),
      );
    }
    return CustodyCatalog(
      epoch: epoch,
      enabled: v['enabled'] as bool,
      entries: List.unmodifiable(result),
      pendingPurge: List.unmodifiable(_ids(v['pendingPurge'])),
    );
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
    if (await _call('enableOwner', {'owner': ownerId, 'epoch': epoch}) !=
        null) {
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
          'preserve': snapshot.preserve.toList()..sort(),
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
