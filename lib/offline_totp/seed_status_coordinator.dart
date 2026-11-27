import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// Unregistered seed status coordinator. This transport sends no bearer,
/// cookies or Origin. It cannot fetch seeds or grant a session.
abstract interface class SeedStatusTransport {
  Future<SeedStatusResponse> post(String path, Map<String, Object> body);
}

class SeedStatusResponse {
  const SeedStatusResponse(this.status, this.body, {this.retryAfter});
  final Duration? retryAfter;
  final int status;
  final String body;
}

class SeedStatusOwners {
  const SeedStatusOwners(this.owners, {required this.pendingOrUnreadable});
  final List<String> owners;
  final bool pendingOrUnreadable;
}

abstract interface class SeedStatusNative {
  /// Durable native owner records, independent of session or bearer.
  Future<SeedStatusOwners> owners();

  /// Null includes pending erase or unreadable state. Retry local work first.
  Future<String?> activeKeyId(String owner);
  Future<void> retryPending();
  Future<String> signStatus({
    required String owner,
    required String askedKeyId,
    required String challenge,
    required int expiresAt,
  });

  /// Native atomically compares askedKeyId with current enrollment before erase.
  /// Returns KEPT, PURGED, NOOP, PENDING or UNREADABLE. NOOP means only
  /// the asked key is superseded or gone, never proof of a purge.
  Future<String> applyStatus({
    required String owner,
    required String askedKeyId,
    required String state,
  });
}

enum SeedStatusResult { kept, purged, superseded, retry, deferred }

class SeedStatusSweep {
  SeedStatusSweep(
    Map<String, SeedStatusResult> results, {
    required this.incomplete,
  }) : results = Map.unmodifiable(results);
  final Map<String, SeedStatusResult> results;
  final bool incomplete;
}

/// No background hooks or automatic enrollment. Owners come from native records.
/// Signed snapshot remains the first authenticated seed-sync operation after
/// sign-in; this bearer-free check is also usable after session expiry/revoke.
final class SeedStatusCoordinator {
  SeedStatusCoordinator(
    this.transport,
    this.native, {
    DateTime Function()? clock,
    double Function()? jitter,
  }) : _clock = clock ?? DateTime.now,
       _jitter = jitter ?? Random.secure().nextDouble;
  final SeedStatusTransport transport;
  final SeedStatusNative native;
  final DateTime Function() _clock;
  final double Function() _jitter;
  final _failures = <String, int>{};
  final _serverDelay = <String, Duration>{};

  /// Preserves healthy-owner progress even when discovery is incomplete.
  /// Incomplete or retry/deferred results must not be treated as completion.
  Future<SeedStatusSweep> checkAll() async {
    try {
      try {
        await native.retryPending();
      } catch (_) {}
      final found = await native.owners();
      final results = <String, SeedStatusResult>{};
      for (final owner in found.owners) {
        results[owner] = await check(owner);
      }
      return SeedStatusSweep(results, incomplete: found.pendingOrUnreadable);
    } catch (_) {
      return SeedStatusSweep({}, incomplete: true);
    }
  }

  final _running = <String, Future<SeedStatusResult>>{};
  final _retryAfter = <String, DateTime>{};
  Future<SeedStatusResult> check(String owner) {
    if (_retryAfter[owner]?.isAfter(_clock()) ?? false) {
      return Future.value(SeedStatusResult.deferred);
    }
    return _running.putIfAbsent(
      owner,
      () => _check(owner)
          .then((r) {
            if (r == SeedStatusResult.retry) {
              final n = min((_failures[owner] ?? 0) + 1, 6);
              _failures[owner] = n;
              final local = Duration(
                milliseconds:
                    (30000 * pow(2, n - 1) * (1 + _jitter().clamp(0, 1)))
                        .round(),
              );
              final server = _serverDelay.remove(owner) ?? Duration.zero;
              _retryAfter[owner] = _clock().add(
                local > server ? local : server,
              );
            } else {
              _failures.remove(owner);
              // Engineering throttle, not a user preference or background schedule.
              _retryAfter[owner] = _clock().add(const Duration(minutes: 15));
            }
            return r;
          })
          .whenComplete(() {
            _running.remove(owner);
          }),
    );
  }

  static final _key = RegExp(r'^[a-zA-Z0-9_-]{1,128}$');
  static final _nonce = RegExp(r'^[a-zA-Z0-9_-]{43}$');
  Map<String, dynamic>? _object(String text, Set<String> keys) {
    if (text.length > 4096) return null;
    final v = jsonDecode(text);
    if (v is! Map<String, dynamic> ||
        v.length != keys.length ||
        !keys.every(v.containsKey)) {
      return null;
    }
    return v;
  }

  Future<SeedStatusResult> _check(String owner) async {
    try {
      await native.retryPending();
      final asked = await native.activeKeyId(owner);
      if (asked == null || !_key.hasMatch(asked)) return SeedStatusResult.retry;
      final b = await transport.post('/v1/manage/seed-sync/status-begin', {
        'keyId': asked,
      });
      if (b.status != 200) {
        if (b.retryAfter != null) _serverDelay[owner] = b.retryAfter!;
        return SeedStatusResult.retry;
      }
      final begin = _object(b.body, {'token', 'challenge'});
      if (begin == null ||
          begin['token'] is! String ||
          (begin['token'] as String).isEmpty ||
          (begin['token'] as String).length > 256) {
        return SeedStatusResult.retry;
      }
      final c = begin['challenge'];
      if (c is! Map<String, dynamic> ||
          c.length != 3 ||
          !{'keyId', 'challenge', 'expiresAt'}.every(c.containsKey) ||
          c['keyId'] != asked ||
          c['challenge'] is! String ||
          !_nonce.hasMatch(c['challenge'] as String) ||
          c['expiresAt'] is! int ||
          (c['expiresAt'] as int) < 0 ||
          (c['expiresAt'] as int) > 9007199254740991) {
        return SeedStatusResult.retry;
      }
      final signature = await native.signStatus(
        owner: owner,
        askedKeyId: asked,
        challenge: c['challenge'] as String,
        expiresAt: c['expiresAt'] as int,
      );
      final f = await transport.post('/v1/manage/seed-sync/status-finish', {
        'token': begin['token'] as String,
        'signature': signature,
      });
      if (f.status != 200) {
        if (f.retryAfter != null) _serverDelay[owner] = f.retryAfter!;
        return SeedStatusResult.retry;
      }
      final finish = _object(f.body, {'state'});
      final state = finish?['state'];
      if (state != 'active' &&
          state != 'key-revoked' &&
          state != 'generation-changed') {
        return SeedStatusResult.retry;
      }
      final result = await native.applyStatus(
        owner: owner,
        askedKeyId: asked,
        state: state as String,
      );
      return switch (result) {
        'KEPT' when state == 'active' => SeedStatusResult.kept,
        'PURGED' when state != 'active' => SeedStatusResult.purged,
        'NOOP' => SeedStatusResult.superseded,
        _ => SeedStatusResult.retry,
      };
    } catch (_) {
      return SeedStatusResult.retry;
    }
  }
}
