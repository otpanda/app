// Pure, unwired client contract for the common-horizon TOTP batch response.
// No transport, UI, clipboard, storage, seed handling or numeric defaults:
// every limit comes from the caller's [BatchPolicy]. Codes live in memory
// only. Call clear on logout, account switch, backgrounding and entry
// permission or catalog changes.
//
// Response envelope (server handler finalizeCommonHorizon, status stripped):
//   {serverNow: ms, coverageUntil: ms|null, totalCodes: n,
//    entries: [{entryId, period: s, digits: 6|7|8, validFrom: s, codes: [str]}],
//    omitted: [{entryId, reason: 'period_too_short'|'unavailable'}]}
// codes[i] is valid for [validFrom + i*period, validFrom + (i+1)*period)
// seconds. The server guarantees the first code is valid at serverNow, every
// entry covers at least coverageUntil, and a failed check is a 503, never a
// partial body.

const _safeInteger = 9007199254740991;
bool _integer(Object? n) => n is int && n >= 0 && n <= _safeInteger;
final _idChars = RegExp(r'[\x00-\x20\x7f]');
bool _entry(Object? id) =>
    id is String && id.isNotEmpty && id.length <= 64 && !_idChars.hasMatch(id);

/// Limits supplied by the caller. No defaults on purpose.
final class BatchPolicy {
  const BatchPolicy({
    required this.maxEntries,
    required this.maxTotalCodes,
    required this.minPeriodSeconds,
    required this.maxPeriodSeconds,
    required this.maxWindowSeconds,
    required this.minRemainingMs,
  });
  final int maxEntries, maxTotalCodes;
  final int minPeriodSeconds, maxPeriodSeconds;

  /// Longest coverage the client will accept from serverNow.
  final int maxWindowSeconds;

  /// Smallest coverageUntil - serverNow the client will accept.
  final int minRemainingMs;
}

/// One validated entry of a batch. Never log or stringify the codes.
final class BatchEntry {
  const BatchEntry._(
    this.entryId,
    this.period,
    this.digits,
    this.validFrom,
    this.codes,
  );
  final String entryId;
  final int period, digits, validFrom;
  final List<String> codes;
  @override
  String toString() => 'BatchEntry(redacted)';
}

final class BatchOmission {
  const BatchOmission(this.entryId, this.periodTooShort);
  final String entryId;
  final bool periodTooShort;
}

final class CommonHorizonBatch {
  const CommonHorizonBatch._(
    this.serverNow,
    this.coverageUntil,
    this.entries,
    this.omitted,
  );
  final int serverNow;
  final int? coverageUntil;
  final List<BatchEntry> entries;
  final List<BatchOmission> omitted;

  /// Strict parse. Throws [FormatException] for anything unexpected: unknown or
  /// missing keys, wrong types, ids not requested or duplicated, requested ids
  /// missing from both lists, bad period, digits, alignment, code shape, code
  /// count, totals, coverage or a first code not valid at serverNow.
  factory CommonHorizonBatch.parse(
    Object? json, {
    required Set<String> requestedIds,
    required BatchPolicy policy,
  }) {
    Never bad() => throw const FormatException('Invalid batch');
    if (requestedIds.isEmpty ||
        requestedIds.length > policy.maxEntries ||
        !requestedIds.every(_entry) ||
        policy.minPeriodSeconds < 1 ||
        policy.maxPeriodSeconds < policy.minPeriodSeconds ||
        policy.maxPeriodSeconds > 86400 ||
        policy.maxWindowSeconds < 1 ||
        policy.minRemainingMs < 1 ||
        policy.maxTotalCodes < 1) {
      bad();
    }
    if (json is! Map<String, dynamic> ||
        json.length != 5 ||
        !{
          'serverNow',
          'coverageUntil',
          'totalCodes',
          'entries',
          'omitted',
        }.every(json.containsKey)) {
      bad();
    }
    final serverNow = json['serverNow'], coverage = json['coverageUntil'];
    final total = json['totalCodes'];
    final entriesRaw = json['entries'], omittedRaw = json['omitted'];
    if (!_integer(serverNow) ||
        !_integer(total) ||
        (coverage != null && !_integer(coverage)) ||
        entriesRaw is! List ||
        omittedRaw is! List ||
        entriesRaw.length + omittedRaw.length != requestedIds.length) {
      bad();
    }
    final now = serverNow as int;
    final seen = <String>{};
    void see(Object? id) {
      if (!_entry(id) ||
          !requestedIds.contains(id) ||
          !seen.add(id as String)) {
        bad();
      }
    }

    final omitted = <BatchOmission>[];
    for (final o in omittedRaw) {
      if (o is! Map<String, dynamic> ||
          o.length != 2 ||
          !o.containsKey('entryId') ||
          !o.containsKey('reason')) {
        bad();
      }
      see(o['entryId']);
      final reason = o['reason'];
      if (reason != 'period_too_short' && reason != 'unavailable') bad();
      omitted.add(
        BatchOmission(o['entryId'] as String, reason == 'period_too_short'),
      );
    }
    final entries = <BatchEntry>[];
    var count = 0;
    for (final e in entriesRaw) {
      if (e is! Map<String, dynamic> ||
          e.length != 5 ||
          !{
            'entryId',
            'period',
            'digits',
            'validFrom',
            'codes',
          }.every(e.containsKey)) {
        bad();
      }
      see(e['entryId']);
      final p = e['period'], digits = e['digits'], from = e['validFrom'];
      final codes = e['codes'];
      if (!_integer(p) ||
          !_integer(from) ||
          digits is! int ||
          (digits != 6 && digits != 7 && digits != 8) ||
          codes is! List ||
          codes.isEmpty) {
        bad();
      }
      final period = p as int, start = from as int;
      if (period < policy.minPeriodSeconds ||
          period > policy.maxPeriodSeconds ||
          start % period != 0) {
        bad();
      }
      final shape = RegExp('^[0-9]{$digits}\$');
      for (final c in codes) {
        if (c is! String || !shape.hasMatch(c)) bad();
      }
      final n = codes.length;
      count += n;
      if (count > policy.maxTotalCodes) bad();
      final tailSeconds = start + n * period;
      // Each entry's last code ends at or after coverageUntil, and the first
      // code is the one valid at serverNow (the server drops expired heads).
      if (tailSeconds > _safeInteger ~/ 1000 ||
          start * 1000 > now ||
          (start + period) * 1000 <= now ||
          coverage == null ||
          tailSeconds * 1000 < (coverage as int) ||
          tailSeconds * 1000 - now >
              (policy.maxWindowSeconds + period) * 1000) {
        bad();
      }
      entries.add(
        BatchEntry._(
          e['entryId'] as String,
          period,
          digits,
          start,
          List.unmodifiable(codes.cast<String>()),
        ),
      );
    }
    if (count != total || seen.length != requestedIds.length) bad();
    if (entries.isEmpty) {
      if (coverage != null || total != 0) bad();
    } else {
      final c = coverage as int;
      if (c - now < policy.minRemainingMs ||
          c - now > policy.maxWindowSeconds * 1000) {
        bad();
      }
    }
    return CommonHorizonBatch._(
      now,
      coverage as int?,
      List.unmodifiable(entries),
      List.unmodifiable(omitted),
    );
  }
}

/// A code that is valid right now under the conservative clock.
final class BatchCode {
  const BatchCode._(
    this.entryId,
    this.value,
    this.period,
    this.remainingMs,
    this.periodStartMs,
  );
  final String entryId, value;
  final int period;

  /// Milliseconds until this code stops being valid, rounded down by the
  /// latest possible server clock.
  final int remainingMs;

  /// Start of this code's period, in server milliseconds. With [entryId] it
  /// identifies the code without using its value (for UI keys).
  final int periodStartMs;
  @override
  String toString() => 'BatchCode(redacted)';
}

/// Token for one in-flight request. Created before the request is sent.
final class BatchRequest {
  const BatchRequest._(this._sequence, this._generation, this._began, this.ids);
  final int _sequence, _generation, _began;
  final Set<String> ids;
}

class _Held {
  _Held(this.entry, this.loOffset, this.hiOffset, this.coverageUntil);
  final BatchEntry entry;

  /// Server time at monotonic tick t is within [t + loOffset, t + hiOffset]:
  /// serverNow was stamped somewhere between sending and receiving.
  final int loOffset, hiOffset, coverageUntil;
}

/// Memory-only store of batched codes with a conservative monotonic clock.
///
/// Time model: serverNow was stamped some time between the moment the request
/// was started and the moment the response arrived, so the server clock at any
/// later tick is only known to lie in a range as wide as the network time. A
/// code is offered only when it is valid across the whole range, so a code
/// never shows early or late. Near each period boundary this hides the code
/// for up to the round-trip time; callers should refresh before the end of
/// coverage and may prefer a short round trip.
final class BatchCodeStore {
  BatchCodeStore({required this.monotonicMilliseconds});
  final int Function() monotonicMilliseconds;
  int _generation = 0, _sequence = 0, _accepted = 0;
  int? _lastTick;
  final _held = <String, _Held>{};
  final omitted = <String, String>{};
  final _omittedAt = <String, int>{};
  bool omissionRetryDue(String id) {
    try {
      return omitted[id] == 'unavailable' &&
          _tick() - (_omittedAt[id] ?? _tick()) >= 60000;
    } catch (_) {
      clear();
      return false;
    }
  }

  int entryCoverageRemainingMs(String id) {
    try {
      final h = _held[id];
      return h == null ? 0 : h.coverageUntil - (_tick() + h.hiOffset);
    } catch (_) {
      clear();
      return 0;
    }
  }

  bool hasCoverage(String id) {
    final h = _held[id];
    if (h == null) return false;
    try {
      return h.coverageUntil > _tick() + h.hiOffset;
    } catch (_) {
      clear();
      return false;
    }
  }

  // The tick high-water survives clear on purpose: a restarted or broken clock
  // needs a new store with a continuing provider.
  int _tick() {
    final tick = monotonicMilliseconds();
    if (!_integer(tick) || (_lastTick != null && tick < _lastTick!)) {
      throw const FormatException('Clock went backwards');
    }
    _lastTick = tick;
    return tick;
  }

  /// Starts a request for [ids]. Invalid input or a broken clock clears the
  /// store and throws.
  BatchRequest begin(Set<String> ids) {
    try {
      if (ids.isEmpty || !ids.every(_entry)) {
        throw const FormatException('Invalid ids');
      }
      return BatchRequest._(
        ++_sequence,
        _generation,
        _tick(),
        Set.unmodifiable(ids),
      );
    } catch (_) {
      clear();
      rethrow;
    }
  }

  /// Applies a response. Returns false and changes nothing when the request
  /// is stale: cleared since it began, or older than a response already
  /// accepted. Throws [FormatException] (and clears everything) for an
  /// invalid response or a broken clock. Entries not in the request keep their
  /// still-valid codes; requested entries are replaced; omitted ones are
  /// removed.
  bool accept(
    BatchRequest request,
    Object? json, {
    required BatchPolicy policy,
  }) {
    if (request._generation != _generation || request._sequence <= _accepted) {
      return false;
    }
    try {
      final now = _tick();
      if (now < request._began) throw const FormatException('Clock');
      final batch = CommonHorizonBatch.parse(
        json,
        requestedIds: request.ids,
        policy: policy,
      );
      final lo = batch.serverNow - now;
      final hi = batch.serverNow - request._began;
      // Coverage must still be ahead under the latest possible server clock.
      final c = batch.coverageUntil;
      if (c != null && c - (now + hi) < 1) {
        throw const FormatException('Expired on arrival');
      }
      for (final id in request.ids) {
        _held.remove(id);
        omitted.remove(id);
        _omittedAt.remove(id);
      }
      for (final e in batch.entries) {
        _held[e.entryId] = _Held(e, lo, hi, batch.coverageUntil!);
      }
      for (final o in batch.omitted) {
        omitted[o.entryId] = o.periodTooShort
            ? 'period_too_short'
            : 'unavailable';
        _omittedAt[o.entryId] = now;
      }
      _accepted = request._sequence;
      return true;
    } catch (e) {
      if (e is! FormatException || e.message != 'Expired on arrival') clear();
      rethrow;
    }
  }

  /// The code for [entryId] if it is valid at every server time the clock
  /// allows, else null. Also the only value a copy action may use.
  BatchCode? current(String entryId) {
    final int t;
    try {
      t = _tick();
    } catch (_) {
      clear();
      return null;
    }
    final h = _held[entryId];
    if (h == null) return null;
    final e = h.entry;
    final startMs = e.validFrom * 1000, periodMs = e.period * 1000;
    final low = t + h.loOffset, high = t + h.hiOffset;
    if (low < startMs) return null;
    final iLow = (low - startMs) ~/ periodMs,
        iHigh = (high - startMs) ~/ periodMs;
    if (iLow != iHigh || iHigh >= e.codes.length) return null;
    return BatchCode._(
      entryId,
      e.codes[iHigh],
      e.period,
      startMs + (iHigh + 1) * periodMs - high,
      startMs + iHigh * periodMs,
    );
  }

  /// Next instant the strict displayed value can change, using held clock bounds.
  /// A caller can repaint then rather than waiting for a one-second UI tick.
  int? nextBoundaryDelayMs(String id) {
    try {
      final h = _held[id];
      if (h == null) return null;
      final t = _tick(), e = h.entry;
      final start = e.validFrom * 1000, period = e.period * 1000;
      final low = t + h.loOffset, high = t + h.hiOffset;
      if (low < start || high >= h.coverageUntil) return null;
      final first = (low - start) ~/ period, last = (high - start) ~/ period;
      if (last >= e.codes.length) return null;
      final next = first == last
          ? start + (last + 1) * period - high
          : start + (first + 1) * period - low;
      return next > 0 ? next : 1;
    } catch (_) {
      clear();
      return null;
    }
  }

  /// True only when authenticated held codes cover both sides of an uncertain
  /// boundary. Neither code is safe to show or copy yet. This is not an empty
  /// account or a failed request, and never grants access to either value.
  bool awaitingBoundary(String id) {
    try {
      final h = _held[id];
      if (h == null) return false;
      final t = _tick(), e = h.entry;
      final start = e.validFrom * 1000, period = e.period * 1000;
      final low = t + h.loOffset, high = t + h.hiOffset;
      if (low < start || high >= h.coverageUntil) return false;
      final first = (low - start) ~/ period, last = (high - start) ~/ period;
      return first != last && first >= 0 && last < e.codes.length;
    } catch (_) {
      clear();
      return false;
    }
  }

  /// True when a code after the current one is held for [id], so the tile can
  /// change at the next boundary without a request.
  bool hasNextCode(String id) {
    final h = _held[id];
    if (h == null) return false;
    try {
      final e = h.entry;
      final startMs = e.validFrom * 1000, periodMs = e.period * 1000;
      final i = (_tick() + h.hiOffset - startMs) ~/ periodMs;
      return i >= 0 && i + 1 < e.codes.length;
    } catch (_) {
      clear();
      return false;
    }
  }

  /// Entry ids that currently have a valid code, in no particular order.
  List<String> available() => [
    for (final id in _held.keys.toList())
      if (current(id) != null) id,
  ];

  /// Milliseconds of coverage left under the latest server clock, 0 when none.
  int coverageRemainingMs() {
    if (_held.isEmpty) return 0;
    try {
      final t = _tick();
      int? minimum;
      for (final h in _held.values) {
        final tail =
            (h.entry.validFrom + h.entry.codes.length * h.entry.period) * 1000;
        final end = tail < h.coverageUntil ? tail : h.coverageUntil;
        final remaining = end - (t + h.hiOffset);
        // Expired retained entries must not force a loop for a newer selection.
        if (remaining > 0 && (minimum == null || remaining < minimum)) {
          minimum = remaining;
        }
      }
      return minimum ?? 0;
    } catch (_) {
      clear();
      return 0;
    }
  }

  /// True when no coverage is held or it ends within [leadMs]. The caller
  /// chooses the lead; there is no default.
  bool needsRefresh({required int leadMs}) {
    if (leadMs < 0) throw ArgumentError.value(leadMs, 'leadMs');
    return coverageRemainingMs() <= leadMs;
  }

  /// Drops every code and invalidates all in-flight requests.
  void clear() {
    _generation++;
    _held.clear();
    omitted.clear();
    _omittedAt.clear();
  }
}
