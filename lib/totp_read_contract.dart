import 'dart:convert';

import 'session_contract.dart';

const _safeInteger = 9007199254740991;
bool _integer(Object? n) => n is int && n >= 0 && n <= _safeInteger;
bool _entry(Object? id) =>
    id is String &&
    id.isNotEmpty &&
    id.length <= 256 &&
    !RegExp(r'[\x00-\x20\x7f]').hasMatch(id);

/// Generated-code intervals are Unix seconds, unlike received-code milliseconds.
/// Never convert this into a persisted delivered-code record.
final class GeneratedTotp {
  final String entryId, value;
  final int period, validFrom, validUntil, serverNow;
  const GeneratedTotp._(
    this.entryId,
    this.value,
    this.period,
    this.validFrom,
    this.validUntil,
    this.serverNow,
  );
  factory GeneratedTotp.fromJson(Map<String, dynamic> body) {
    const fields = {
      'entryId',
      'code',
      'period',
      'validFrom',
      'validUntil',
      'serverNow',
    };
    final id = body['entryId'], value = body['code'];
    final p = body['period'],
        start = body['validFrom'],
        end = body['validUntil'];
    final serverNow = body['serverNow'];
    if (body.length != fields.length ||
        !body.keys.every(fields.contains) ||
        !_entry(id) ||
        value is! String ||
        !RegExp(r'^\d{6,8}$').hasMatch(value) ||
        !_integer(p) ||
        p == 0 ||
        p > 86400 ||
        !_integer(start) ||
        !_integer(end) ||
        end - start != p ||
        start % p != 0 ||
        end > _safeInteger ~/ 1000 ||
        !_integer(serverNow) ||
        serverNow ~/ 1000 < start ||
        serverNow ~/ 1000 >= end) {
      throw const FormatException('Invalid generated code');
    }
    return GeneratedTotp._(id as String, value, p, start, end, serverNow);
  }
  @override
  String toString() => 'GeneratedTotp(redacted)';
}

/// Unwired read contract. One selected entry, memory only, no background polling,
/// storage, seed import, clipboard or platform integration. Call clear on logout,
/// account switch, backgrounding and entry permission/catalog changes.
final class TotpReadStore {
  /// Must fetch fresh authenticated HTTPS responses, with no cache, replay,
  /// response memoization, service-worker response substitution or stale fallback.
  /// serverNow is only trustworthy as time for this in-flight response under
  /// that transport contract. Production adapters must be tested for this.
  final SessionTransport transport;
  int _generation = 0;
  final int Function() monotonicMilliseconds;
  int? _startedAt, _deadline, _lastTick;
  GeneratedTotp? _code;
  TotpReadStore(this.transport, {required this.monotonicMilliseconds});
  // clear intentionally keeps this high-water mark. A restarted/broken clock
  // requires a new store with a continuing provider, never resetting an active
  // store to revive old state. Invalid visibility ticks cancel pending loads.
  int _tick() {
    final tick = monotonicMilliseconds();
    if (!_integer(tick) || (_lastTick != null && tick < _lastTick!)) {
      throw const FormatException();
    }
    _lastTick = tick;
    return tick;
  }

  GeneratedTotp? visible() {
    try {
      final now = _tick();
      if (_startedAt != null &&
          now >= _startedAt! &&
          _deadline != null &&
          now < _deadline!) {
        return _code;
      }
    } catch (_) {
      clear();
    }
    if (_code != null) clear();
    return null;
  }

  int remainingSeconds() {
    if (visible() == null) return 0;
    try {
      return ((_deadline! - _tick()) / 1000).ceil().clamp(0, 86400);
    } catch (_) {
      clear();
      return 0;
    }
  }

  void clear() {
    _generation++;
    _startedAt = null;
    _deadline = null;
    _code = null;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await transport.getManagement(path);
    if (response.status != 200) throw ClientFailure(response.status);
    if (utf8.encode(response.body).length > 4096) {
      throw const FormatException();
    }
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  Future<void> load(String entryId) async {
    clear();
    final generation = _generation;
    try {
      if (!_entry(entryId)) throw const FormatException();
      final began = _tick();
      final session = await _get('/v1/manage/session');
      if (generation != _generation) return;
      final expiresField = session['expiresAt'];
      if (!_entry(session['ownerId']) || !_integer(expiresField)) {
        throw const ClientFailure(401);
      }
      final expires = expiresField as int;
      final body = await _get(
        '/v1/manage/totp-code?${Uri(queryParameters: {'entry': entryId}).query}',
      );
      if (generation != _generation) return;
      final code = GeneratedTotp.fromJson(body), now = _tick();
      final elapsed = now - began;
      if (expires - code.serverNow <= elapsed) throw const ClientFailure(401);
      final codeRemaining = code.validUntil * 1000 - code.serverNow - elapsed;
      final sessionRemaining = expires - code.serverNow - elapsed;
      final remaining = codeRemaining < sessionRemaining
          ? codeRemaining
          : sessionRemaining;
      if (code.entryId != entryId ||
          remaining <= 0 ||
          now > _safeInteger - remaining) {
        throw const FormatException();
      }
      _startedAt = now;
      _deadline = now + remaining;
      _code = code;
    } catch (error) {
      if (generation != _generation) return;
      clear();
      if (error is ClientFailure) rethrow;
      throw const ClientFailure();
    }
  }
}
