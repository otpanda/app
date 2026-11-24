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
  final int period, validFrom, validUntil;
  const GeneratedTotp._(
    this.entryId,
    this.value,
    this.period,
    this.validFrom,
    this.validUntil,
  );
  factory GeneratedTotp.fromJson(Map<String, dynamic> body) {
    const fields = {'entryId', 'code', 'period', 'validFrom', 'validUntil'};
    final id = body['entryId'], value = body['code'];
    final p = body['period'],
        start = body['validFrom'],
        end = body['validUntil'];
    if (body.length != fields.length ||
        !body.keys.every(fields.contains) ||
        !_entry(id) ||
        value is! String ||
        !RegExp(r'^\d{6}(?:\d{2})?$').hasMatch(value) ||
        !_integer(p) ||
        p == 0 ||
        p > 86400 ||
        !_integer(start) ||
        !_integer(end) ||
        end - start != p ||
        start % p != 0) {
      throw const FormatException('Invalid generated code');
    }
    return GeneratedTotp._(id as String, value, p, start, end);
  }
  bool activeAtMilliseconds(int now) =>
      _integer(now) && validFrom <= now ~/ 1000 && now ~/ 1000 < validUntil;
  int remainingSeconds(int now) =>
      activeAtMilliseconds(now) ? validUntil - now ~/ 1000 : 0;
  @override
  String toString() => 'GeneratedTotp(redacted)';
}

/// Unwired read contract. One selected entry, memory only, no background polling,
/// storage, seed import, clipboard or platform integration. Call clear on logout,
/// account switch, backgrounding and entry permission/catalog changes.
final class TotpReadStore {
  final SessionTransport transport;
  int _generation = 0;
  int? _sessionExpiresAt;
  GeneratedTotp? _code;
  TotpReadStore(this.transport);
  GeneratedTotp? visible(int now) =>
      _sessionExpiresAt != null &&
          now < _sessionExpiresAt! &&
          (_code?.activeAtMilliseconds(now) ?? false)
      ? _code
      : null;
  void clear() {
    _generation++;
    _sessionExpiresAt = null;
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

  Future<void> load(String entryId, int Function() clock) async {
    clear();
    final generation = _generation;
    try {
      if (!_entry(entryId) || !_integer(clock())) throw const FormatException();
      final session = await _get('/v1/manage/session');
      if (generation != _generation) return;
      final expires = session['expiresAt'];
      if (!_entry(session['ownerId']) ||
          !_integer(expires) ||
          expires <= clock()) {
        throw const ClientFailure(401);
      }
      final body = await _get(
        '/v1/manage/totp-code?${Uri(queryParameters: {'entry': entryId}).query}',
      );
      if (generation != _generation) return;
      final code = GeneratedTotp.fromJson(body), now = clock();
      if (expires <= now) throw const ClientFailure(401);
      if (code.entryId != entryId || !code.activeAtMilliseconds(now)) {
        throw const FormatException();
      }
      _sessionExpiresAt = expires;
      _code = code;
    } catch (error) {
      if (generation != _generation) return;
      clear();
      if (error is ClientFailure) rethrow;
      throw const ClientFailure();
    }
  }
}
