import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../native/native_device_routes.dart' show DevicePost;

/// Strict HTTP adapter for the four signed seed-sync pull routes:
/// snapshot-begin, snapshot-finish, batch-begin, batch-finish. Unregistered:
/// nothing constructs it in production. It owns no session, key, proof or native
/// handle and retries nothing.
///
/// Requests go through the existing [DevicePost] (android bearer, no cookies, no
/// Origin, no query). Every request key set is exact, every 200 body must match
/// its shape exactly, and the finish echoes are checked against the values the
/// caller sent. The server answers every state failure with an opaque 409, so no
/// failure here proves an operation did not commit or that nothing was released.
///
/// The only specific 409 bodies are the signed-shape codes `key-revoked` and
/// `generation-changed`, returned by the server only after the request's own
/// signature verified. They are surfaced as typed results and never acted on
/// here: this adapter purges and erases nothing.

const seedSyncPullBase = '/v1/manage/seed-sync/';

/// Exact request key sets, as the server enforces them (src/seed-sync-http.js).
const seedSyncPullBodyKeys = <String, Set<String>>{
  'snapshot-begin': {'epoch', 'keyId'},
  'snapshot-finish': {'signature', 'token'},
  'batch-begin': {'entries', 'ephemeralKey', 'epoch', 'keyId'},
  'batch-finish': {'signature', 'token'},
};

/// Server cap on a snapshot (SNAPSHOT_CAP) and tombstone list (TOMBSTONE_LIMIT).
const seedSyncSnapshotCap = 1000;
const seedSyncTombstoneLimit = 200;

/// True when [op] and [body] are an allowed pull request.
bool seedSyncPullRequestAllowed(String op, Map<String, dynamic> body) {
  final keys = seedSyncPullBodyKeys[op];
  if (keys == null) return false;
  if (body.length != keys.length || !keys.every(body.containsKey)) return false;
  return utf8.encode(jsonEncode(body)).length <= 4096;
}

final _token = RegExp(r'^otpda_[A-Za-z0-9_-]{55}$');
final _nonce = RegExp(r'^[A-Za-z0-9_-]{43}$');
final _hex64 = RegExp(r'^[0-9a-f]{64}$');
final _hex32 = RegExp(r'^[0-9a-f]{32}$');
final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _sig = RegExp(r'^[A-Za-z0-9_-]{86}$');
const _maxSafe = 9007199254740991;
const _algorithms = {'SHA-1', 'SHA-256', 'SHA-512'};

String sha256HexOf(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();

String sha256HexOfBytes(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

/// Why a pull request failed, for the caller's decision. Never a purge reason.
enum SeedSyncPullFailure {
  /// Non-200 (including the opaque 409 and 429/503) or an unreadable reply.
  /// Not-committed and transient look identical: unknown outcome.
  unavailable,

  /// A 200 that does not match the exact shape or the echoes. Treat as hostile.
  shape,
}

final class SeedSyncPullException implements Exception {
  const SeedSyncPullException(this.reason);
  final SeedSyncPullFailure reason;
  @override
  String toString() => 'SeedSyncPullException(${reason.name})';
}

/// A signed-request definitive code. Informational: nothing is purged here.
/// The caller confirms with a key-signed status request before erasing anything.
enum SeedSyncSignedState { keyRevoked, generationChanged }

final class SeedSyncSignedStateException implements Exception {
  const SeedSyncSignedStateException(this.state);
  final SeedSyncSignedState state;
  @override
  String toString() => 'SeedSyncSignedStateException(${state.name})';
}

final class SeedSyncChallenge {
  const SeedSyncChallenge({
    required this.token,
    required this.ownerId,
    required this.keyId,
    required this.deviceId,
    required this.generation,
    required this.epoch,
    required this.challenge,
    required this.expiresAt,
    this.ephemeralDigest,
    this.entriesDigest,
  });
  final String token, ownerId, keyId, deviceId, challenge;
  final int generation, epoch, expiresAt;

  /// Batch challenges only.
  final String? ephemeralDigest, entriesDigest;
}

final class SeedSyncSnapshotEntry {
  const SeedSyncSnapshotEntry(
    this.entryId,
    this.seedVersion,
    this.algorithm,
    this.digits,
    this.period,
  );
  final String entryId, algorithm;
  final int seedVersion, digits, period;
}

final class SeedSyncSnapshot {
  SeedSyncSnapshot({
    required this.ownerId,
    required this.deviceId,
    required this.epoch,
    required this.challengeDigest,
    required this.revision,
    required this.complete,
    required this.maxBatch,
    required List<SeedSyncSnapshotEntry> entries,
    required Map<String, String> unsupported,
    required Map<String, int> tombstones,
  }) : entries = List.unmodifiable(entries),
       unsupported = Map.unmodifiable(unsupported),
       tombstones = Map.unmodifiable(tombstones);
  final String ownerId, deviceId, challengeDigest;
  final int epoch, revision, maxBatch;

  /// False when the server had more than the snapshot cap: no removal by absence.
  final bool complete;
  final List<SeedSyncSnapshotEntry> entries;

  /// entryId to reason (`unsupported` or `metadata_pending`). Never sealed.
  final Map<String, String> unsupported;

  /// entryId to the highest tombstone revision (the version floor).
  final Map<String, int> tombstones;
}

enum SeedSyncResultStatus { sealed, stale, removed, unsupported }

final class SeedSyncBatchResult {
  const SeedSyncBatchResult({
    required this.entryId,
    required this.status,
    this.seedVersion,
    this.algorithm,
    this.digits,
    this.period,
    this.nonce,
    this.ciphertext,
  });
  final String entryId;
  final SeedSyncResultStatus status;

  /// Sealed entries only: the version, metadata and AEAD fields. Not seed bytes.
  final int? seedVersion, digits, period;
  final String? algorithm, nonce, ciphertext;
}

final class SeedSyncBatch {
  SeedSyncBatch({
    required this.ownerId,
    required this.deviceId,
    required this.epoch,
    required this.challengeDigest,
    required this.serverPublicKey,
    required List<SeedSyncBatchResult> results,
  }) : results = List.unmodifiable(results);
  final String ownerId, deviceId, challengeDigest;
  final int epoch;

  /// Null exactly when no result is sealed.
  final String? serverPublicKey;
  final List<SeedSyncBatchResult> results;
}

/// Server side of the pull contract. Every failure is an exception; none proves
/// that an operation did not commit.
abstract interface class SeedSyncPullApi {
  Future<SeedSyncChallenge> snapshotBegin({
    required String keyId,
    required int epoch,
  });
  Future<SeedSyncSnapshot> snapshotFinish({
    required SeedSyncChallenge challenge,
    required String signature,
  });
  Future<SeedSyncChallenge> batchBegin({
    required String keyId,
    required int epoch,
    required String ephemeralKey,
    required List<({String entryId, int seedVersion})> entries,
  });
  Future<SeedSyncBatch> batchFinish({
    required SeedSyncChallenge challenge,
    required String signature,
  });
}

final class SeedSyncHttp implements SeedSyncPullApi {
  SeedSyncHttp({required this._post});
  final DevicePost _post;

  Never _shape() =>
      throw const SeedSyncPullException(SeedSyncPullFailure.shape);
  Never _down() =>
      throw const SeedSyncPullException(SeedSyncPullFailure.unavailable);

  Future<({int status, Map<String, dynamic>? body})> _send(
    String op,
    Map<String, dynamic> body,
  ) {
    if (!seedSyncPullRequestAllowed(op, body)) {
      throw StateError('Seed-sync request not allowed');
    }
    return _post('$seedSyncPullBase$op', body);
  }

  bool _exact(Map<dynamic, dynamic> m, Set<String> keys) =>
      m.length == keys.length && keys.every(m.containsKey);

  int _int(Object? v, {int min = 0, int max = _maxSafe}) {
    if (v is! int || v < min || v > max) _shape();
    return v;
  }

  String _str(Object? v, RegExp pattern) {
    if (v is! String || !pattern.hasMatch(v)) _shape();
    return v;
  }

  /// A signed-request definitive 409, or a normal failure. Always throws.
  Never _failure(({int status, Map<String, dynamic>? body}) r) {
    final b = r.body;
    if (r.status == 409 && b != null && b.length == 1 && b['error'] is String) {
      switch (b['error']) {
        case 'key-revoked':
          throw const SeedSyncSignedStateException(
            SeedSyncSignedState.keyRevoked,
          );
        case 'generation-changed':
          throw const SeedSyncSignedStateException(
            SeedSyncSignedState.generationChanged,
          );
      }
    }
    _down();
  }

  Map<String, dynamic> _okBody(
    ({int status, Map<String, dynamic>? body}) r,
    Set<String> keys,
  ) {
    if (r.status != 200) _failure(r);
    final b = r.body;
    if (b == null || !_exact(b, keys)) _shape();
    return b;
  }

  SeedSyncChallenge _challenge(
    Map<String, dynamic> b, {
    required String purposeKeyId,
    required int epoch,
    required bool batch,
  }) {
    final c = b['challenge'];
    final keys = <String>{
      'ownerId',
      'keyId',
      'deviceId',
      'generation',
      'epoch',
      'challenge',
      'expiresAt',
      if (batch) ...{'ephemeralDigest', 'entriesDigest'},
    };
    if (c is! Map || !_exact(c, keys)) _shape();
    final out = SeedSyncChallenge(
      token: _str(b['token'], _token),
      ownerId: _str(c['ownerId'], _id),
      keyId: _str(c['keyId'], _id),
      deviceId: _str(c['deviceId'], _id),
      generation: _int(c['generation']),
      epoch: _int(c['epoch']),
      challenge: _str(c['challenge'], _nonce),
      expiresAt: _int(c['expiresAt']),
      ephemeralDigest: batch ? _str(c['ephemeralDigest'], _hex64) : null,
      entriesDigest: batch ? _str(c['entriesDigest'], _hex64) : null,
    );
    // Echoes of what this client asked for. A different key or epoch means the
    // server is not answering this request.
    if (out.keyId != purposeKeyId || out.epoch != epoch) _shape();
    return out;
  }

  @override
  Future<SeedSyncChallenge> snapshotBegin({
    required String keyId,
    required int epoch,
  }) async {
    if (!_hex32.hasMatch(keyId) || epoch < 0 || epoch > _maxSafe) {
      throw ArgumentError('invalid key id or epoch');
    }
    final r = await _send('snapshot-begin', {'epoch': epoch, 'keyId': keyId});
    final b = _okBody(r, {'token', 'challenge'});
    return _challenge(b, purposeKeyId: keyId, epoch: epoch, batch: false);
  }

  @override
  Future<SeedSyncSnapshot> snapshotFinish({
    required SeedSyncChallenge challenge,
    required String signature,
  }) async {
    if (!_sig.hasMatch(signature)) throw ArgumentError('signature shape');
    final r = await _send('snapshot-finish', {
      'signature': signature,
      'token': challenge.token,
    });
    final b = _okBody(r, {
      'ownerId',
      'deviceId',
      'epoch',
      'challengeDigest',
      'revision',
      'complete',
      'maxBatch',
      'entries',
      'unsupported',
      'tombstones',
    });
    if (b['ownerId'] != challenge.ownerId ||
        b['deviceId'] != challenge.deviceId ||
        b['epoch'] != challenge.epoch ||
        b['challengeDigest'] != sha256HexOf(challenge.challenge) ||
        b['complete'] is! bool) {
      _shape();
    }
    final entries = b['entries'], unsupported = b['unsupported'];
    final tombstones = b['tombstones'];
    if (entries is! List ||
        unsupported is! List ||
        tombstones is! List ||
        entries.length + unsupported.length > seedSyncSnapshotCap ||
        tombstones.length > seedSyncTombstoneLimit) {
      _shape();
    }
    final seen = <String>{};
    final parsed = <SeedSyncSnapshotEntry>[];
    for (final e in entries) {
      if (e is! Map ||
          !_exact(e, {
            'entryId',
            'seedVersion',
            'algorithm',
            'digits',
            'period',
          })) {
        _shape();
      }
      final id = _str(e['entryId'], _id);
      if (!seen.add(id)) _shape();
      final algorithm = e['algorithm'];
      if (algorithm is! String || !_algorithms.contains(algorithm)) _shape();
      parsed.add(
        SeedSyncSnapshotEntry(
          id,
          _int(e['seedVersion'], min: 1),
          algorithm,
          _int(e['digits'], min: 6, max: 8),
          _int(e['period'], min: 1, max: 86400),
        ),
      );
    }
    final unsup = <String, String>{};
    for (final u in unsupported) {
      if (u is! Map || !_exact(u, {'entryId', 'reason'})) _shape();
      final id = _str(u['entryId'], _id);
      final reason = u['reason'];
      if (!seen.add(id) ||
          (reason != 'unsupported' && reason != 'metadata_pending')) {
        _shape();
      }
      unsup[id] = reason as String;
    }
    final floors = <String, int>{};
    for (final t in tombstones) {
      if (t is! Map || !_exact(t, {'entryId', 'revision'})) _shape();
      final id = _str(t['entryId'], _id);
      final rev = _int(t['revision'], min: 1);
      // The server lists one row per deletion: the same entry may repeat. The
      // floor is the highest.
      if ((floors[id] ?? 0) < rev) floors[id] = rev;
    }
    final revision = _int(b['revision']);
    // A listed version must be above its own tombstone floor (custody refuses
    // the same contradiction). Versions are not compared with the revision:
    // pre-migration rows carry version 1 while the owner revision is still 0.
    for (final e in parsed) {
      final floor = floors[e.entryId];
      if (floor != null && e.seedVersion <= floor) _shape();
    }
    return SeedSyncSnapshot(
      ownerId: challenge.ownerId,
      deviceId: challenge.deviceId,
      epoch: challenge.epoch,
      challengeDigest: b['challengeDigest'] as String,
      revision: revision,
      complete: b['complete'] as bool,
      maxBatch: _int(b['maxBatch'], min: 1, max: 3),
      entries: parsed,
      unsupported: unsup,
      tombstones: floors,
    );
  }

  @override
  Future<SeedSyncChallenge> batchBegin({
    required String keyId,
    required int epoch,
    required String ephemeralKey,
    required List<({String entryId, int seedVersion})> entries,
  }) async {
    if (!_hex32.hasMatch(keyId) ||
        epoch < 0 ||
        epoch > _maxSafe ||
        entries.isEmpty ||
        entries.length > 3 ||
        entries.map((e) => e.entryId).toSet().length != entries.length ||
        !entries.every(
          (e) =>
              _id.hasMatch(e.entryId) &&
              e.seedVersion >= 1 &&
              e.seedVersion <= _maxSafe,
        )) {
      throw ArgumentError('invalid batch request');
    }
    List<int> raw;
    try {
      raw = base64Url.decode('$ephemeralKey=');
    } on FormatException {
      throw ArgumentError('ephemeral key');
    }
    if (ephemeralKey.length != 87 ||
        raw.length != 65 ||
        raw[0] != 4 ||
        base64UrlEncode(raw).replaceAll('=', '') != ephemeralKey) {
      throw ArgumentError('ephemeral key');
    }
    final r = await _send('batch-begin', {
      'entries': [
        for (final e in entries)
          {'entryId': e.entryId, 'seedVersion': e.seedVersion},
      ],
      'ephemeralKey': ephemeralKey,
      'epoch': epoch,
      'keyId': keyId,
    });
    final b = _okBody(r, {'token', 'challenge'});
    final c = _challenge(b, purposeKeyId: keyId, epoch: epoch, batch: true);
    final sorted = [...entries]..sort((a, b) => a.entryId.compareTo(b.entryId));
    final expectedEntries = sha256HexOf(
      jsonEncode([
        for (final e in sorted) [e.entryId, e.seedVersion],
      ]),
    );
    if (c.entriesDigest != expectedEntries ||
        c.ephemeralDigest != crypto.sha256.convert(raw).toString()) {
      _shape();
    }
    return c;
  }

  @override
  Future<SeedSyncBatch> batchFinish({
    required SeedSyncChallenge challenge,
    required String signature,
  }) async {
    if (!_sig.hasMatch(signature)) throw ArgumentError('signature shape');
    final r = await _send('batch-finish', {
      'signature': signature,
      'token': challenge.token,
    });
    final b = _okBody(r, {
      'ownerId',
      'deviceId',
      'epoch',
      'challengeDigest',
      'serverPublicKey',
      'results',
    });
    if (b['ownerId'] != challenge.ownerId ||
        b['deviceId'] != challenge.deviceId ||
        b['epoch'] != challenge.epoch ||
        b['challengeDigest'] != sha256HexOf(challenge.challenge)) {
      _shape();
    }
    final rows = b['results'];
    if (rows is! List || rows.length > 3) _shape();
    final seen = <String>{};
    final out = <SeedSyncBatchResult>[];
    for (final row in rows) {
      if (row is! Map || row['entryId'] is! String) _shape();
      final id = _str(row['entryId'], _id);
      if (!seen.add(id)) _shape();
      switch (row['status']) {
        case 'removed' || 'unsupported':
          if (!_exact(row, {'entryId', 'status'})) _shape();
          out.add(
            SeedSyncBatchResult(
              entryId: id,
              status: row['status'] == 'removed'
                  ? SeedSyncResultStatus.removed
                  : SeedSyncResultStatus.unsupported,
            ),
          );
        case 'stale':
          // The server sends stale with the newer version when it saw it, and
          // without when the entry changed after decrypt.
          if (row.length == 3 &&
              _exact(row, {'entryId', 'status', 'seedVersion'})) {
            out.add(
              SeedSyncBatchResult(
                entryId: id,
                status: SeedSyncResultStatus.stale,
                seedVersion: _int(row['seedVersion'], min: 1),
              ),
            );
          } else if (_exact(row, {'entryId', 'status'})) {
            out.add(
              SeedSyncBatchResult(
                entryId: id,
                status: SeedSyncResultStatus.stale,
              ),
            );
          } else {
            _shape();
          }
        case 'sealed':
          if (!_exact(row, {
            'entryId',
            'status',
            'seedVersion',
            'algorithm',
            'digits',
            'period',
            'nonce',
            'ciphertext',
          })) {
            _shape();
          }
          final algorithm = row['algorithm'];
          if (algorithm is! String || !_algorithms.contains(algorithm)) {
            _shape();
          }
          out.add(
            SeedSyncBatchResult(
              entryId: id,
              status: SeedSyncResultStatus.sealed,
              seedVersion: _int(row['seedVersion'], min: 1),
              algorithm: algorithm,
              digits: _int(row['digits'], min: 6, max: 8),
              period: _int(row['period'], min: 1, max: 86400),
              nonce: _b64(row['nonce'], 12, 12),
              ciphertext: _b64(row['ciphertext'], 26, 144),
            ),
          );
        default:
          _shape();
      }
    }
    final sealedAny = out.any((e) => e.status == SeedSyncResultStatus.sealed);
    final spk = b['serverPublicKey'];
    if (sealedAny) {
      if (spk is! String || spk.length != 87) _shape();
      List<int> raw;
      try {
        raw = base64Url.decode('$spk=');
      } on FormatException {
        _shape();
      }
      if (raw.length != 65 ||
          raw[0] != 4 ||
          base64UrlEncode(raw).replaceAll('=', '') != spk) {
        _shape();
      }
    } else if (spk != null) {
      _shape();
    }
    return SeedSyncBatch(
      ownerId: challenge.ownerId,
      deviceId: challenge.deviceId,
      epoch: challenge.epoch,
      challengeDigest: b['challengeDigest'] as String,
      serverPublicKey: spk as String?,
      results: out,
    );
  }

  /// Canonical unpadded base64url with a decoded length in [min, max].
  String _b64(Object? v, int min, int max) {
    if (v is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v)) _shape();
    try {
      final b = base64Url.decode(base64Url.normalize(v));
      if (b.length < min ||
          b.length > max ||
          base64UrlEncode(b).replaceAll('=', '') != v) {
        _shape();
      }
    } on FormatException {
      _shape();
    }
    return v;
  }
}
