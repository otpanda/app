import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'session_contract.dart';

const _safeInteger = 9007199254740991;

/// Entries per request (the server accepts 1 to 5).
const totpBatchMaxEntries = 5;

/// Entries prefetched per window, fetched as sequential requests of at most
/// [totpBatchMaxEntries]. Anything beyond is requested one code at a time.
const totpBatchMaxTracked = 20;

/// Requests one chain may send. A chain never loops: it stops here, on a rate
/// limit, or when nothing needs fetching.
const totpBatchMaxChain = totpBatchMaxTracked ~/ totpBatchMaxEntries;
const totpBatchMaxWindowSeconds = 600;
const totpBatchMaxBytes = 16384;
const totpBatchMaxIdLength = 64;
const totpBatchRefreshLeadMs = 60000;

bool _int(Object? n) => n is int && n >= 0 && n <= _safeInteger;
bool _id(Object? id) =>
    id is String &&
    id.isNotEmpty &&
    id.length <= 256 &&
    !RegExp(r'[\x00-\x20\x7f]').hasMatch(id);

/// Fetches one batch of generated codes for the given entries.
abstract interface class TotpBatchBridge {
  Future<SessionResponse> totpCodes(List<String> entryIds);
}

/// A code that is current now, with whole seconds left in its period.
final class BatchCode {
  final String entryId, value;
  final int secondsLeft, period;
  const BatchCode(this.entryId, this.value, this.secondsLeft, this.period);
  @override
  String toString() => 'BatchCode(redacted)';
}

class _Suspended implements Exception {
  const _Suspended();
}

class _Series {
  final int period, validFrom;
  final List<String> codes;
  const _Series(this.period, this.validFrom, this.codes);
}

/// What one response granted: its own clock anchor and hard expiry.
class _Batch {
  final int anchorMono, anchorServerMs, expiresMono;
  final Map<String, _Series> series;
  final Set<String> omitted;
  const _Batch(
    this.anchorMono,
    this.anchorServerMs,
    this.expiresMono,
    this.series,
    this.omitted,
  );
}

/// Codes only, never seeds. Memory only: nothing is persisted, logged or put
/// in a route. A batch is usable until its explicit expiry (the window the
/// server granted, counted from when the request started, never more than 600
/// seconds) and never past the end of the signed-in session. The period-aligned
/// end of the last code is not permission to show anything.
///
/// Time comes from the server's `serverNow` plus the monotonic clock, so a
/// wrong device clock does not matter.
final class TotpBatchStore {
  final BrowserBatchFetch fetch;
  final int Function() monotonicMilliseconds;

  /// Device wall clock, used only as a delta against the monotonic clock to
  /// notice that the page was suspended. Its absolute value is never used.
  final int Function() wallMilliseconds;

  /// The signed-in session's expiry in server milliseconds. It is read once per
  /// batch and counted down with the monotonic clock, so the batch never
  /// outlives the session.
  final Future<int> Function() sessionExpiresAt;
  final Random _random;
  int _generation = 0, _lastTick = 0, _failures = 0;
  int? _lastWall, _backoffUntil;

  /// Set when the server has no batch route (404 or 501). Batching then stops for the life of this store, kept across
  /// clear(), so callers use single-code requests and nothing is retried against a route that does not exist.
  bool _unavailable = false;
  bool get unavailable => _unavailable;

  /// Entry id to the response that carries (or omits) it.
  final Map<String, _Batch> _byId = {};

  /// Per entry: when it may be requested again after a failed request, and how
  /// many times in a row it failed.
  final Map<String, int> _idUntil = {}, _idFails = {};
  Future<void>? _inFlight;
  List<String> _wanted = const [];
  int _rotate = 0;
  final List<(Set<String>, Completer<void>, int)> _waiters = [];

  TotpBatchStore({
    required this.fetch,
    required this.monotonicMilliseconds,
    int Function()? wallMilliseconds,
    required this.sessionExpiresAt,
    Random? random,
  }) : wallMilliseconds =
           wallMilliseconds ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random();

  /// A wall clock that ran ahead of the monotonic clock by more than this means
  /// the page was suspended (a monotonic clock may pause in sleep), so a batch
  /// may be older than it looks.
  static const suspendSlackMs = 5000;

  int _tick() {
    final t = monotonicMilliseconds();
    if (!_int(t) || t < _lastTick) throw const FormatException();
    final wall = wallMilliseconds();
    final lastWall = _lastWall;
    final lastMono = _lastTick;
    _lastTick = t;
    _lastWall = wall;
    if (lastWall != null &&
        (wall - lastWall) - (t - lastMono) > suspendSlackMs) {
      throw const _Suspended();
    }
    return t;
  }

  /// Exponential, jittered: 5 s, 10 s, 20 s ... up to 2 minutes (a rate limit
  /// starts at 30 s and goes up to 5 minutes). Reset by a good response.
  int _backoff(int now, {bool limited = false}) {
    _failures = min(_failures + 1, 10);
    final base = (limited ? 30000 : 5000) * (1 << min(_failures - 1, 6));
    final capped = min(base, limited ? 300000 : 120000);
    return now + capped + _random.nextInt(capped ~/ 2 + 1);
  }

  bool get hasBatch => _byId.isNotEmpty;

  /// Entry ids whose codes this batch carries and can still show.
  bool covers(String entryId) => codeFor(entryId) != null;

  /// True when the entry was left out by the server (for example a very short
  /// period), so the caller falls back to a single-code request.
  bool omitted(String entryId) =>
      _byId[entryId]?.omitted.contains(entryId) ?? false;

  /// The code to show for [entryId] right now, or null. Checked on every call
  /// so an expired batch never shows a stale code.
  BatchCode? codeFor(String entryId) {
    try {
      final now = _tick();
      final b = _byId[entryId];
      if (b == null) return null;
      if (now >= b.expiresMono) {
        _byId.removeWhere((_, v) => identical(v, b));
        return null;
      }
      final s = b.series[entryId];
      if (s == null) return null;
      final serverMs = b.anchorServerMs + (now - b.anchorMono);
      final sec = serverMs ~/ 1000;
      final i = (sec - s.validFrom) ~/ s.period;
      if (sec < s.validFrom || i >= s.codes.length) return null;
      final left = s.validFrom + (i + 1) * s.period - sec;
      return BatchCode(entryId, s.codes[i], left, s.period);
    } catch (_) {
      clear();
      return null;
    }
  }

  /// Milliseconds until the earliest held response should be refreshed (lead
  /// before its expiry), or null when none is held.
  int? msUntilRefresh() {
    try {
      if (_byId.isEmpty) return null;
      final now = _tick();
      return _byId.values.map((b) => b.expiresMono).reduce(min) -
          totpBatchRefreshLeadMs -
          now;
    } catch (_) {
      clear();
      return null;
    }
  }

  bool _needs(String id, int now) {
    final b = _byId[id];
    if (b == null || now >= b.expiresMono) return true;
    if (b.expiresMono - totpBatchRefreshLeadMs - now <= 0) return true;
    return !b.omitted.contains(id) && codeFor(id) == null;
  }

  /// True if any of [ids] has no usable code and is not omitted, or its
  /// response is within the refresh lead of its expiry. Cheap, no request.
  bool needsFetch(Iterable<String> ids) {
    try {
      final now = _tick();
      if (_unavailable || (_backoffUntil ?? 0) > now) return false;
      return ids.any((id) => (_idUntil[id] ?? 0) <= now && _needs(id, now));
    } catch (_) {
      clear();
      return true;
    }
  }

  List<String> _tracked(List<String> ids) => {...ids, ..._wanted}
      .where((i) => i.length <= totpBatchMaxIdLength)
      .take(totpBatchMaxTracked)
      .toList();

  /// Loads codes for at most 20 entries as sequential requests of at most 5,
  /// never in parallel, one chain per store. Entries named in this call go
  /// first. The returned future completes when every entry in [ids] has a code
  /// or is omitted, or when the chain ends. A rate limit stops the chain and
  /// backs off; a failed request backs off only its own entries so the others
  /// still load. Entries beyond 20 are never requested here and are served one
  /// at a time by the caller.
  Future<void> ensure(List<String> ids) {
    final want = _tracked(ids);
    if (want.isEmpty) return Future.value();
    _wanted = want;
    final mine = ids.where((i) => i.length <= totpBatchMaxIdLength).toSet();
    try {
      final now = _tick();
      if (_unavailable) return Future.value();
      if (_backoffUntil != null && now < _backoffUntil!) return Future.value();
      if (_inFlight == null &&
          !want.any((id) => (_idUntil[id] ?? 0) <= now && _needs(id, now))) {
        return Future.value();
      }
    } catch (_) {
      clear();
      return Future.value();
    }
    if (_inFlight == null) {
      late final Future<void> f;
      final gen = _generation;
      f = _chain().whenComplete(() {
        // A newer chain may have started after clear(); never drop that one,
        // nor its callers.
        if (identical(_inFlight, f)) _inFlight = null;
        for (final w in _waiters.where((w) => w.$3 == gen).toList()) {
          if (!w.$2.isCompleted) w.$2.complete();
          _waiters.remove(w);
        }
      });
      _inFlight = f;
    }
    final c = Completer<void>();
    _waiters.add((mine, c, _generation));
    _notify();
    return c.future;
  }

  void _notify() {
    final done = <(Set<String>, Completer<void>, int)>[];
    for (final w in _waiters) {
      final ready = w.$1.every((id) {
        final b = _byId[id];
        return b != null &&
            (b.omitted.contains(id) || b.series.containsKey(id));
      });
      if (ready) {
        if (!w.$2.isCompleted) w.$2.complete();
        done.add(w);
      }
    }
    _waiters.removeWhere(done.contains);
  }

  /// The next up to 5 entries to request: the ones this round's callers named
  /// first, then the rest in rotation, skipping entries still backing off.
  List<String> _next(int now) {
    final w = _wanted;
    if (w.isEmpty) return const [];
    final start = _rotate % w.length;
    final order = [...w.skip(start), ...w.take(start)];
    final out = <String>[];
    for (final id in order) {
      if ((_idUntil[id] ?? 0) > now) continue;
      if (_needs(id, now)) out.add(id);
      if (out.length == totpBatchMaxEntries) break;
    }
    return out;
  }

  Future<void> _chain() async {
    final generation = _generation;
    try {
      final sessionEnd = await sessionExpiresAt();
      if (generation != _generation) return;
      if (!_int(sessionEnd)) throw const ClientFailure(401);
      for (var sent = 0; sent < totpBatchMaxChain; sent++) {
        final now = _tick();
        if (_backoffUntil != null && now < _backoffUntil!) return;
        final group = _next(now);
        if (group.isEmpty) return;
        final ok = await _load(group, sessionEnd, generation);
        if (generation != _generation) return;
        if (ok == null) return; // rate limited: stop the chain
        _rotate += group.length;
        _notify();
      }
    } catch (error) {
      if (generation != _generation) return;
      if (error is _Suspended) {
        clear();
        return;
      }
      try {
        _backoffUntil = _backoff(_tick());
      } catch (_) {
        clear();
      }
      // The callers hear about an authorization failure, never an unhandled
      // error on the chain itself.
      if (error is ClientFailure) _failWaiters(error);
    }
  }

  void _failWaiters(Object error) {
    final ws = List.of(_waiters);
    _waiters.clear();
    for (final w in ws) {
      if (!w.$2.isCompleted) w.$2.completeError(error);
    }
  }

  /// One request. Returns true on success, false on a failure that backs off
  /// only these entries, null on a rate limit (global back-off, stop).
  Future<bool?> _load(List<String> want, int sessionEnd, int generation) async {
    try {
      final began = _tick();
      final response = await fetch(want);
      if (generation != _generation) return false;
      final received = _tick();
      if (response.status == 429) {
        _backoffUntil = _backoff(received, limited: true);
        return null;
      }
      if (response.status == 404 || response.status == 501) {
        _unavailable = true;
        return null; // stop the chain; no back-off loop against a missing route
      }
      if (response.status == 401 || response.status == 403) {
        final failed = ClientFailure(response.status);
        _failWaiters(failed);
        clear();
        throw failed;
      }
      if (response.status != 200) {
        _failIds(want, received);
        return false;
      }
      if (utf8.encode(response.body).length > totpBatchMaxBytes) {
        throw const FormatException();
      }
      final parsed = _parse(response.body, want);
      // serverNow was sampled during the request: anchor at its midpoint.
      final anchor = began + (received - began) ~/ 2;
      final sessionLeft = sessionEnd - parsed.serverNow;
      if (sessionLeft <= 0) throw const ClientFailure(401);
      final int capped = min(
        began + parsed.window * 1000,
        anchor + sessionLeft,
      );
      if (capped <= received) throw const FormatException();
      final batch = _Batch(
        anchor,
        parsed.serverNow,
        capped,
        parsed.series,
        parsed.omitted,
      );
      for (final id in [...parsed.series.keys, ...parsed.omitted]) {
        _byId[id] = batch;
        _idUntil.remove(id);
        _idFails.remove(id);
      }
      // Entries the server neither served nor omitted keep no stale code and
      // back off like a failed request, so a chain never asks again at once.
      final missing = [
        for (final id in want)
          if (!batch.series.containsKey(id) && !batch.omitted.contains(id)) id,
      ];
      for (final id in missing) {
        _byId.remove(id);
      }
      if (missing.isNotEmpty) _failIds(missing, received);
      _backoffUntil = null;
      _failures = 0;
      return true;
    } catch (error) {
      if (generation != _generation) return false;
      if (error is _Suspended) {
        clear();
        return false;
      }
      if (error is ClientFailure) rethrow;
      // A bad or failed response never replaces a still-valid response, and
      // backs off only the entries it was for.
      try {
        _failIds(want, _tick());
      } catch (_) {
        clear();
      }
      return false;
    }
  }

  void _failIds(List<String> ids, int now) {
    for (final id in ids) {
      final f = min((_idFails[id] ?? 0) + 1, 10);
      _idFails[id] = f;
      final base = 5000 * (1 << min(f - 1, 6));
      final capped = min(base, 120000);
      _idUntil[id] = now + capped + _random.nextInt(capped ~/ 2 + 1);
    }
  }

  ({
    int window,
    int windowExpiresAt,
    int serverNow,
    Map<String, _Series> series,
    Set<String> omitted,
  })
  _parse(String body, List<String> requested) {
    final v = jsonDecode(body);
    if (v is! Map<String, dynamic>) throw const FormatException();
    const keys = {
      'serverNow',
      'windowSeconds',
      'windowExpiresAt',
      'entries',
      'omitted',
    };
    if (!v.keys.every(keys.contains) || v.length != keys.length) {
      throw const FormatException();
    }
    final serverNow = v['serverNow'], window = v['windowSeconds'];
    final entries = v['entries'], omitted = v['omitted'];
    final expiresAt = v['windowExpiresAt'];
    if (!_int(serverNow) ||
        !_int(window) ||
        !_int(expiresAt) ||
        (expiresAt as int) % 1000 != 0 ||
        window < 1 ||
        window > totpBatchMaxWindowSeconds ||
        entries is! List ||
        omitted is! List) {
      throw const FormatException();
    }
    // Generation started at expiresAt - window, no later than serverNow and
    // not long before it.
    final startedAt = expiresAt - (window as int) * 1000;
    if (startedAt > serverNow || serverNow - startedAt > 10000) {
      throw const FormatException();
    }
    final asked = requested.toSet(), seen = <String>{};
    final series = <String, _Series>{};
    final sec = serverNow ~/ 1000;
    for (final e in entries) {
      if (e is! Map<String, dynamic>) throw const FormatException();
      const f = {'entryId', 'period', 'digits', 'validFrom', 'codes'};
      if (e.length != f.length || !e.keys.every(f.contains)) {
        throw const FormatException();
      }
      final id = e['entryId'], p = e['period'], d = e['digits'];
      final from = e['validFrom'], codes = e['codes'];
      if (!_id(id) ||
          !asked.contains(id) ||
          !seen.add(id as String) ||
          !_int(p) ||
          p < 1 ||
          p > 86400 ||
          (d != 6 && d != 8) ||
          !_int(from) ||
          from % p != 0 ||
          codes is! List ||
          codes.isEmpty ||
          codes.length > (window / p).ceil() + 1) {
        throw const FormatException();
      }
      for (final c in codes) {
        if (c is! String || c.length != d || !RegExp(r'^\d+$').hasMatch(c)) {
          throw const FormatException();
        }
      }
      // The first code must actually cover the server time.
      if (sec < from || sec >= from + (p as int)) {
        throw const FormatException();
      }
      series[id] = _Series(p, from, codes.cast<String>());
    }
    final out = <String>{};
    for (final o in omitted) {
      if (o is! Map<String, dynamic> ||
          o.length != 2 ||
          !_id(o['entryId']) ||
          !asked.contains(o['entryId']) ||
          o['reason'] is! String ||
          !const {'period_too_short', 'unavailable'}.contains(o['reason']) ||
          seen.contains(o['entryId']) ||
          !out.add(o['entryId'] as String)) {
        throw const FormatException();
      }
    }
    return (
      window: window,
      windowExpiresAt: expiresAt,
      serverNow: serverNow,
      series: series,
      omitted: out,
    );
  }

  /// Keep only entries that still exist in the catalog: drops them from the
  /// next request set and from the held codes.
  void retain(Set<String> catalogIds) {
    _wanted = [
      for (final id in _wanted)
        if (catalogIds.contains(id)) id,
    ];
    _byId.removeWhere((id, _) => !catalogIds.contains(id));
    _idUntil.removeWhere((id, _) => !catalogIds.contains(id));
    _idFails.removeWhere((id, _) => !catalogIds.contains(id));
  }

  /// Logout, session loss, 401/403, account switch, unload, detach.
  void clear() {
    _generation++;
    _backoffUntil = null;
    _failures = 0;
    _lastWall = null;
    _byId.clear();
    _idUntil.clear();
    _idFails.clear();
    _inFlight = null;
    _wanted = const [];
    _rotate = 0;
    for (final w in _waiters) {
      if (!w.$2.isCompleted) w.$2.complete();
    }
    _waiters.clear();
  }
}

typedef BrowserBatchFetch = Future<SessionResponse> Function(
  List<String> entryIds,
);
