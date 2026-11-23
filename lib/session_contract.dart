import 'dart:convert';

/// Platform adapters own cookies/secure credentials, redirect rejection and
/// no-store policy. This contract never accepts automation tokens as sessions.
abstract interface class SessionTransport {
  Future<SessionResponse> getManagement(String path);
  Future<void> close();
}

class SessionResponse {
  final int status;
  final String body;
  const SessionResponse(this.status, this.body);
  @override
  String toString() => 'SessionResponse($status, redacted)';
}

class ClientFailure implements Exception {
  final int? status;
  const ClientFailure([this.status]);
  bool get signedOut => status == 401;
  @override
  String toString() => signedOut
      ? 'Your session ended. Sign in again.'
      : status == 429
      ? 'Too many requests. Wait before trying again.'
      : 'Could not load codes. Try again.';
}

class ManagedEntry {
  final String id, service, account;
  final bool manage;
  const ManagedEntry(this.id, this.service, this.account, this.manage);
  factory ManagedEntry.fromJson(Map<String, dynamic> json) {
    final capabilities = json['capabilities'];
    if (capabilities is! Map<String, dynamic> ||
        capabilities['manage'] is! bool) {
      throw const FormatException('Invalid entry capabilities');
    }
    return ManagedEntry(
      _text(json, 'entry_id'),
      _text(json, 'service_name'),
      json['account_name'] == null ? '' : _text(json, 'account_name'),
      capabilities['manage'] == true,
    );
  }
}

class ReceivedCode {
  final String entryId, value;
  final int receivedAt, expiresAt;
  const ReceivedCode._(
    this.entryId,
    this.value,
    this.receivedAt,
    this.expiresAt,
  );
  factory ReceivedCode.fromJson(Map<String, dynamic> json) {
    final received = json['receivedAt'], expires = json['expiresAt'];
    final value = _text(json, 'code', max: 32);
    if (received is! int ||
        expires is! int ||
        received < 0 ||
        expires <= received) {
      throw const FormatException('Invalid code lifetime');
    }
    return ReceivedCode._(_text(json, 'entryId'), value, received, expires);
  }
  bool active(int now) => receivedAt <= now && now < expiresAt;
  @override
  String toString() => 'ReceivedCode(redacted)';
}

String _text(Map<String, dynamic> json, String key, {int max = 256}) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > max) {
    throw const FormatException('Invalid response field');
  }
  return value;
}

/// In-memory only. UI must call clear on logout, backgrounding and account
/// changes, and use visibleCodes with a live clock before rendering or copying.
class CodeStore {
  final SessionTransport transport;
  int _generation = 0;
  List<ManagedEntry> _entries = const [];
  List<ReceivedCode> _codes = const [];
  CodeStore(this.transport);
  List<ManagedEntry> get entries => List.unmodifiable(_entries);
  List<ReceivedCode> visibleCodes(int now) =>
      List.unmodifiable(_codes.where((code) => code.active(now)));

  void clear() {
    _generation++;
    _entries = const [];
    _codes = const [];
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await transport.getManagement(path);
    if (response.status != 200) throw ClientFailure(response.status);
    if (utf8.encode(response.body).length > 512 * 1024) {
      throw const FormatException('Response too large');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Object response required');
    }
    return body;
  }

  Future<void> load(int Function() clock) async {
    clear();
    final generation = _generation;
    try {
      final session = await _get('/v1/manage/session');
      _text(session, 'ownerId');
      final expires = session['expiresAt'];
      if (expires is! int || expires <= clock()) {
        throw const ClientFailure(401);
      }
      if (generation != _generation) return;
      final entryBody = await _get('/v1/manage/entries');
      if (generation != _generation) return;
      final entries = _list(
        entryBody,
        'entries',
        100,
      ).map(ManagedEntry.fromJson).toList();
      if (entries.map((e) => e.id).toSet().length != entries.length) {
        throw const FormatException('Duplicate entry');
      }
      final codeBody = await _get('/v1/manage/active-codes');
      if (generation != _generation) return;
      final known = entries.map((entry) => entry.id).toSet();
      final now = clock();
      final codes =
          _list(codeBody, 'records', 100)
              .map(ReceivedCode.fromJson)
              .where((code) => known.contains(code.entryId) && code.active(now))
              .toList()
            ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      _entries = entries;
      _codes = codes;
    } catch (error) {
      if (generation != _generation) return;
      clear();
      if (error is ClientFailure) rethrow;
      // Never surface response payloads, code values or adapter diagnostics.
      throw const ClientFailure();
    }
  }
}

List<Map<String, dynamic>> _list(
  Map<String, dynamic> body,
  String key,
  int max,
) {
  final list = body[key];
  if (list is! List ||
      list.length > max ||
      list.any((item) => item is! Map<String, dynamic>)) {
    throw const FormatException('Invalid response list');
  }
  return list.cast<Map<String, dynamic>>();
}
