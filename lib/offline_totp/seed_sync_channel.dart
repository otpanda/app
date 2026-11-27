import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Every failure is non-purging. In particular, a transport timeout means the
/// native mutation may have completed. The caller must read durable state before
/// deciding whether to retry. This adapter never retries, erases or re-enrolls.
enum SeedSyncFailureKind {
  notEnrolled,
  missingKey,
  unavailable,
  metadataUnavailable,
  invalidInput,
  eraseIncomplete,
  installIdUnreadable,
  installIdMismatch,
  busy,
  wire,
  custody,
  malformedReply,
  unknownOutcome,
}

final class SeedSyncFailure implements Exception {
  const SeedSyncFailure(this.kind);
  final SeedSyncFailureKind kind;
  @override
  String toString() => 'SeedSyncFailure(${kind.name})';
}

final class SeedEnrollment {
  SeedEnrollment(
    this.keyId,
    Uint8List publicKey,
    this.generation,
    this.installId,
  ) : _publicKey = Uint8List.fromList(publicKey);
  final String keyId, installId;
  final int generation;
  final Uint8List _publicKey;
  Uint8List get publicKey => Uint8List.fromList(_publicKey);
}

final class SeedEnrollmentState {
  const SeedEnrollmentState(this.keyId, this.provable);
  final String? keyId;

  /// Only enrollment proof availability in this process, not server acceptance.
  final bool provable;
}

final class SeedEraseResult {
  const SeedEraseResult(this.seedsPurged, this.keyDeleted, this.epoch);
  final bool seedsPurged, keyDeleted;
  final int epoch;
  bool get complete => seedsPurged && keyDeleted;
}

enum SeedEraseReason { signOut, disable, ownerSwitch }

final class SeedBatchEntry {
  const SeedBatchEntry(
    this.entryId,
    this.seedVersion,
    this.algorithm,
    this.digits,
    this.periodSeconds,
  );
  final String entryId, algorithm;
  final int seedVersion, digits, periodSeconds;
  Map<String, Object> toWire() => {
    'entryId': entryId,
    'seedVersion': seedVersion,
    'algorithm': algorithm,
    'digits': digits,
    'periodSeconds': periodSeconds,
  };
}

final class SeedBatchStart {
  const SeedBatchStart(this.handleId, this.ephemeralPublic);
  final String handleId;

  /// Canonical unpadded base64url public point, as the native wire sends it.
  final String ephemeralPublic;
}

/// Inactive client boundary for the existing native contract. It constructs no
/// platform host or session and has no network access. No seed/private key is an
/// input or reply. Native owns proof bytes, clock, key binding and sealed open.
/// After ANY uncertain batch mutation, abandon that handle locally. Finish is
/// idempotent best-effort cleanup, not permission to replay sign/open. Unknown
/// begin may occupy a native slot until its 150s TTL; BUSY is not an erase reason.
/// After uncertain enroll/erase, reconcile durable owner/enrollment state and
/// previously journaled intent. This wrapper stores no intent or confirmation.
final class SeedSyncChannel {
  SeedSyncChannel(this.channel, {this.timeout = const Duration(seconds: 15)});
  final MethodChannel channel;
  final Duration timeout;
  static const max = 9007199254740991;
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final _hex = RegExp(r'^[a-f0-9]{32}$');
  static final _install = RegExp(r'^[A-Za-z0-9_-]{22,64}$');
  static const _errors = {
    'NOT_ENROLLED': SeedSyncFailureKind.notEnrolled,
    'MISSING_KEY': SeedSyncFailureKind.missingKey,
    'UNAVAILABLE': SeedSyncFailureKind.unavailable,
    'METADATA_UNAVAILABLE': SeedSyncFailureKind.metadataUnavailable,
    'INVALID_INPUT': SeedSyncFailureKind.invalidInput,
    'ERASE_INCOMPLETE': SeedSyncFailureKind.eraseIncomplete,
    'INSTALL_ID_UNREADABLE': SeedSyncFailureKind.installIdUnreadable,
    'INSTALL_ID_MISMATCH': SeedSyncFailureKind.installIdMismatch,
    'BUSY': SeedSyncFailureKind.busy,
  };
  static const _custodyErrors = {
    'LOCKED',
    'NOT_FOUND',
    'TAMPER',
    'VERSION_CONFLICT',
    'STALE_EPOCH',
    'EPOCH_MISMATCH',
    'DENIED',
    'DISABLED',
    'STALE_SNAPSHOT',
    'INVALID_SNAPSHOT',
    'UNSUPPORTED_SEED',
  };
  Never _bad() =>
      throw const SeedSyncFailure(SeedSyncFailureKind.malformedReply);
  Never _input() =>
      throw const SeedSyncFailure(SeedSyncFailureKind.invalidInput);
  Future<Object?> _call(
    String method,
    Map<String, Object?> args, {
    bool mutation = false,
  }) async {
    try {
      return await channel.invokeMethod<Object?>(method, args).timeout(timeout);
    } on TimeoutException {
      throw SeedSyncFailure(
        mutation
            ? SeedSyncFailureKind.unknownOutcome
            : SeedSyncFailureKind.unavailable,
      );
    } on MissingPluginException {
      throw const SeedSyncFailure(SeedSyncFailureKind.unavailable);
    } on PlatformException catch (e) {
      final kind =
          _errors[e.code] ??
          (e.code.startsWith('WIRE_')
              ? SeedSyncFailureKind.wire
              : _custodyErrors.contains(e.code)
              ? SeedSyncFailureKind.custody
              : mutation
              ? SeedSyncFailureKind.unknownOutcome
              : SeedSyncFailureKind.unavailable);
      throw SeedSyncFailure(kind);
    } catch (_) {
      throw SeedSyncFailure(
        mutation
            ? SeedSyncFailureKind.unknownOutcome
            : SeedSyncFailureKind.unavailable,
      );
    }
  }

  /// Malformed mutation replies include failed echoes after a successful call.
  /// None establish whether the side effect happened. Never replay blindly.
  Future<T> _mutation<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on SeedSyncFailure catch (e) {
      if (e.kind == SeedSyncFailureKind.malformedReply) {
        throw const SeedSyncFailure(SeedSyncFailureKind.unknownOutcome);
      }
      rethrow;
    } catch (_) {
      throw const SeedSyncFailure(SeedSyncFailureKind.unknownOutcome);
    }
  }

  Map<Object?, Object?> _map(Object? value, Set<String> keys) {
    if (value is! Map ||
        value.length != keys.length ||
        !keys.every(value.containsKey)) {
      _bad();
    }
    return value;
  }

  String _str(Object? v, RegExp pattern) {
    if (v is! String || !pattern.hasMatch(v)) _bad();
    return v;
  }

  int _num(Object? v) {
    if (v is! int || v < 0 || v > max) _bad();
    return v;
  }

  bool _bool(Object? v) {
    if (v is! bool) _bad();
    return v;
  }

  void _owner(String owner) {
    if (!_id.hasMatch(owner)) _input();
  }

  void _number(int v) {
    if (v < 0 || v > max) _input();
  }

  Uint8List _point(Object? v) {
    if (v is! Uint8List || v.length != 65 || v[0] != 4) _bad();
    // Native already verifies the curve. This is strict channel shape only.
    return v;
  }

  String _publicText(Object? value) {
    if (value is! String || value.length != 87) _bad();
    try {
      final bytes = base64Url.decode('$value=');
      if (bytes.length != 65 ||
          bytes[0] != 4 ||
          base64UrlEncode(bytes).replaceAll('=', '') != value) {
        _bad();
      }
    } on FormatException {
      _bad();
    }
    return value;
  }

  String _signature(Object? v) {
    if (v is! String || !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(v)) _bad();
    try {
      final b = base64Url.decode('$v==');
      if (b.length != 64 || base64UrlEncode(b).replaceAll('=', '') != v) _bad();
    } on FormatException {
      _bad();
    }
    return v;
  }

  Future<SeedEnrollmentState> state(String owner) async {
    _owner(owner);
    final m = _map(await _call('syncEnrollmentState', {'owner': owner}), {
      'keyId',
      'provable',
    });
    final key = m['keyId'] == null ? null : _str(m['keyId'], _hex),
        provable = _bool(m['provable']);
    if (key == null && provable) _bad();
    return SeedEnrollmentState(key, provable);
  }

  /// A fresh key is created on every invocation. Never use as an automatic
  /// retry for timeout, missing key, install mismatch or unconfirmed enrollment.
  Future<SeedEnrollment> enroll({
    required String owner,
    required String installId,
    required int generation,
  }) async {
    return _mutation(() async {
      _owner(owner);
      _number(generation);
      if (!_install.hasMatch(installId)) _input();
      final m = _map(
        await _call('syncEnroll', {
          'owner': owner,
          'installId': installId,
          'generation': generation,
        }, mutation: true),
        {'keyId', 'publicKey', 'generation', 'installId'},
      );
      final key = _str(m['keyId'], _hex),
          returnedInstall = _str(m['installId'], _install),
          gen = _num(m['generation']);
      if (returnedInstall != installId || gen != generation) _bad();
      return SeedEnrollment(key, _point(m['publicKey']), gen, returnedInstall);
    });
  }

  Future<String> enrollProof({
    required String owner,
    required String keyId,
    required String challenge,
    required String actionDigest,
    required int expiresAt,
  }) => _proof('syncSignEnrollProof', owner, keyId, challenge, expiresAt, {
    'actionDigest': actionDigest,
  });
  Future<String> snapshotProof({
    required String owner,
    required String keyId,
    required String deviceId,
    required int generation,
    required int epoch,
    required String challenge,
    required int expiresAt,
  }) => _proof('syncSignSnapshotProof', owner, keyId, challenge, expiresAt, {
    'deviceId': deviceId,
    'generation': generation,
    'epoch': epoch,
  });
  Future<String> revokeProof({
    required String owner,
    required String keyId,
    required String deviceId,
    required int generation,
    required String challenge,
    required int expiresAt,
  }) => _proof('syncSignRevokeProof', owner, keyId, challenge, expiresAt, {
    'deviceId': deviceId,
    'generation': generation,
  });
  Future<String> _proof(
    String method,
    String owner,
    String keyId,
    String challenge,
    int expiresAt,
    Map<String, Object> extra,
  ) async {
    _owner(owner);
    _number(expiresAt);
    for (final field in ['generation', 'epoch']) {
      if (extra.containsKey(field)) _number(extra[field] as int);
    }
    if (extra.containsKey('deviceId')) _owner(extra['deviceId'] as String);
    if (extra.containsKey('actionDigest') &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(extra['actionDigest'] as String)) {
      _input();
    }
    if (!_hex.hasMatch(keyId) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(challenge)) {
      _input();
    }
    return _signature(
      await _call(method, {
        'owner': owner,
        'keyId': keyId,
        'challenge': challenge,
        'expiresAt': expiresAt,
        ...extra,
      }),
    );
  }

  Future<SeedEraseResult> erase({
    required String owner,
    required int epoch,
    required SeedEraseReason reason,
  }) async {
    return _mutation(() async {
      _owner(owner);
      _number(epoch);
      final trigger = switch (reason) {
        SeedEraseReason.signOut => 'sign_out',
        SeedEraseReason.disable => 'disable',
        SeedEraseReason.ownerSwitch => 'owner_switch',
      };
      final m = _map(
        await _call('syncErase', {
          'owner': owner,
          'epoch': epoch,
          'trigger': trigger,
        }, mutation: true),
        {'seedsPurged', 'keyDeleted', 'epoch'},
      );
      final e = _num(m['epoch']);
      return SeedEraseResult(
        _bool(m['seedsPurged']),
        _bool(m['keyDeleted']),
        e,
      );
    });
  }

  Future<SeedBatchStart> begin({
    required String owner,
    required String deviceId,
    required int generation,
    required int epoch,
    required List<SeedBatchEntry> entries,
  }) async {
    return _mutation(() async {
      _owner(owner);
      _owner(deviceId);
      _number(generation);
      _number(epoch);
      if (entries.isEmpty ||
          entries.length > 3 ||
          entries.map((e) => e.entryId).toSet().length != entries.length) {
        _input();
      }
      for (final e in entries) {
        _owner(e.entryId);
        _number(e.seedVersion);
        if (!{'SHA-1', 'SHA-256', 'SHA-512'}.contains(e.algorithm) ||
            e.digits < 6 ||
            e.digits > 8 ||
            e.periodSeconds < 1 ||
            e.periodSeconds > 86400) {
          _input();
        }
      }
      final m = _map(
        await _call('syncBatchBegin', {
          'owner': owner,
          'deviceId': deviceId,
          'generation': generation,
          'epoch': epoch,
          'entries': entries.map((e) => e.toWire()).toList(),
        }, mutation: true),
        {'handleId', 'ephemeralPublic'},
      );
      return SeedBatchStart(
        _str(m['handleId'], _hex),
        _publicText(m['ephemeralPublic']),
      );
    });
  }

  Future<void> bind(
    String handleId, {
    required String challenge,
    required int expiresAt,
  }) async {
    return _mutation(() async {
      _handle(handleId);
      _number(expiresAt);
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(challenge)) _input();
      if (await _call('syncBatchBind', {
            'handleId': handleId,
            'challenge': challenge,
            'expiresAt': expiresAt,
          }, mutation: true) !=
          null) {
        _bad();
      }
    });
  }

  void _handle(String handleId) {
    if (!_hex.hasMatch(handleId)) _input();
  }

  Future<String> signBatch(String handleId) async {
    return _mutation(() async {
      _handle(handleId);
      return _signature(
        await _call('syncBatchSign', {'handleId': handleId}, mutation: true),
      );
    });
  }

  void _encodedInput(
    String value, {
    int? exact,
    int min = 0,
    int maxBytes = 144,
  }) {
    if (value.length > maxBytes * 2 ||
        !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
      _input();
    }
    try {
      final b = base64Url.decode(base64Url.normalize(value));
      if ((exact != null && b.length != exact) ||
          b.length < min ||
          b.length > maxBytes ||
          base64UrlEncode(b).replaceAll('=', '') != value) {
        _input();
      }
    } on FormatException {
      _input();
    }
  }

  List<String> _pending(Object? value) {
    final rows = _map(value, {'pending'})['pending'];
    if (rows is! List ||
        rows.length > 3 ||
        rows.toSet().length != rows.length) {
      _bad();
    }
    return List.unmodifiable(rows.map((v) => _str(v, _id)));
  }

  Future<List<String>> open(
    String handleId, {
    required String entryId,
    required String serverPublicKey,
    required String nonce,
    required String ciphertext,
  }) async {
    return _mutation(() async {
      _handle(handleId);
      _owner(entryId);
      _encodedInput(serverPublicKey, exact: 65, maxBytes: 65);
      _encodedInput(nonce, exact: 12, maxBytes: 12);
      _encodedInput(ciphertext, min: 26, maxBytes: 144);
      return _pending(
        await _call('syncBatchOpen', {
          'handleId': handleId,
          'entryId': entryId,
          'serverPublicKey': serverPublicKey,
          'nonce': nonce,
          'ciphertext': ciphertext,
        }, mutation: true),
      );
    });
  }

  Future<List<String>> skip(String handleId, String entryId) async {
    return _mutation(() async {
      _handle(handleId);
      _owner(entryId);
      return _pending(
        await _call('syncBatchSkip', {
          'handleId': handleId,
          'entryId': entryId,
        }, mutation: true),
      );
    });
  }

  Future<void> finish(String handleId) async {
    return _mutation(() async {
      _handle(handleId);
      if (await _call('syncBatchFinish', {
            'handleId': handleId,
          }, mutation: true) !=
          null) {
        _bad();
      }
    });
  }
}
