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
  final int? retryAfterSeconds;
  const SessionResponse(this.status, this.body, {this.retryAfterSeconds});
  @override
  String toString() => 'SessionResponse($status, redacted)';
}

class ClientFailure implements Exception {
  final int? status;
  final int? retryAfterSeconds;
  const ClientFailure([this.status, this.retryAfterSeconds]);
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
  final bool totp;

  /// The catalogue service id the server stores (its primary domain), kept
  /// for cosmetic logo identity only. Null for custom entries.
  final String? serviceId;
  const ManagedEntry(
    this.id,
    this.service,
    this.account,
    this.manage, [
    this.totp = false,
    this.serviceId,
  ]);
  factory ManagedEntry.fromJson(Map<String, dynamic> json) {
    final capabilities = json['capabilities'];
    if (capabilities is! Map<String, dynamic> ||
        capabilities['manage'] is! bool) {
      throw const FormatException('Invalid entry capabilities');
    }
    return ManagedEntry(
      _text(json, 'entry_id'),
      _text(json, json.containsKey('label') ? 'label' : 'service_name'),
      json['account_name'] == null || json['account_name'] == ''
          ? ''
          : _text(json, 'account_name'),
      capabilities['manage'] == true,
      json['service_id'] == 'custom-totp',
      json['service_id'] is String &&
              RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$')
                  .hasMatch(json['service_id'])
          ? json['service_id'] as String
          : null,
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

class PrivateSource {
  final String id, kind, label;
  const PrivateSource(this.id, this.kind, this.label);
  factory PrivateSource.fromJson(Map<String, dynamic> j) {
    final kind = _text(j, 'kind');
    if (!['sms', 'gmail', 'outlook'].contains(kind)) {
      throw const FormatException('Invalid source kind');
    }
    return PrivateSource(
      _text(j, 'source_id'),
      kind,
      _text(j, 'label', max: 120),
    );
  }
  @override
  String toString() => 'PrivateSource(redacted)';
}

class UnassignedCode {
  final String sourceId, eventId, value;
  final int receivedAt, expiresAt;
  const UnassignedCode._(
    this.sourceId,
    this.eventId,
    this.value,
    this.receivedAt,
    this.expiresAt,
  );
  factory UnassignedCode.fromJson(Map<String, dynamic> j) {
    final r = j['receivedAt'],
        e = j['expiresAt'],
        v = _text(j, 'code', max: 32);
    if (r is! int ||
        e is! int ||
        r < 0 ||
        e <= r ||
        e - r > 86400000 ||
        !RegExp(r'^[A-Za-z0-9-]{4,32}$').hasMatch(v)) {
      throw const FormatException('Invalid private code');
    }
    return UnassignedCode._(_text(j, 'sourceId'), _text(j, 'eventId'), v, r, e);
  }
  bool active(int now) => receivedAt <= now && now < expiresAt;
  @override
  String toString() => 'UnassignedCode(redacted)';
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
  int? _sessionExpiresAt;
  void updateSessionExpiry(int expiresAt, int now) {
    if (_sessionExpiresAt != null && expiresAt > now) {
      _sessionExpiresAt = expiresAt;
    }
  }

  bool sessionExpired(int now) =>
      _sessionExpiresAt != null && now >= _sessionExpiresAt!;
  List<ManagedEntry> _entries = const [];
  List<ReceivedCode> _codes = const [];
  List<PrivateSource> _sources = const [];
  List<UnassignedCode> _unassigned = const [];
  List<PrivateSource> get sources => List.unmodifiable(_sources);
  List<UnassignedCode> visibleUnassigned(int now) => List.unmodifiable(
    _unassigned.where((c) => !sessionExpired(now) && c.active(now)),
  );
  CodeStore(this.transport);
  List<ManagedEntry> get entries => List.unmodifiable(_entries);
  List<ReceivedCode> visibleCodes(int now) => List.unmodifiable(
    _codes.where((code) => !sessionExpired(now) && code.active(now)),
  );

  /// Applies a server-confirmed rename or account change to the loaded list.
  /// Unknown ids change nothing. The next full read replaces the whole list.
  void replaceEntry(String id, {String? service, String? account}) {
    _entries = [
      for (final e in _entries)
        e.id == id
            ? ManagedEntry(
                e.id,
                service ?? e.service,
                account ?? e.account,
                e.manage,
                e.totp,
                e.serviceId,
              )
            : e,
    ];
  }

  void clear() {
    _generation++;
    _sessionExpiresAt = null;
    _entries = const [];
    _codes = const [];
    _sources = const [];
    _unassigned = const [];
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await transport.getManagement(path);
    if (response.status != 200) {
      throw ClientFailure(response.status, response.retryAfterSeconds);
    }
    if (utf8.encode(response.body).length > 512 * 1024) {
      throw const FormatException('Response too large');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const FormatException('Object response required');
    }
    return body;
  }

  Future<void> load(
    int Function() clock, {
    bool includePrivateInbox = false,
  }) async {
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
      List<PrivateSource> sources = const [];
      List<UnassignedCode> unassigned = const [];
      if (includePrivateInbox) {
        final sourceBody = await _get('/v1/manage/sources');
        if (generation != _generation) return;
        sources = _list(sourceBody, 'sources', 100)
            .where((j) => j['revoked_at'] == null)
            .map(PrivateSource.fromJson)
            .toList();
        if (sources.map((s) => s.id).toSet().length != sources.length) {
          throw const FormatException('Duplicate source');
        }
        final inboxBody = await _get('/v1/manage/unassigned');
        if (generation != _generation) return;
        final knownSources = sources.map((s) => s.id).toSet();
        unassigned =
            _list(inboxBody, 'records', 20)
                .map(UnassignedCode.fromJson)
                .where(
                  (c) => knownSources.contains(c.sourceId) && c.active(clock()),
                )
                .toList()
              ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
        if (unassigned
                .map((c) => jsonEncode([c.sourceId, c.eventId]))
                .toSet()
                .length !=
            unassigned.length) {
          throw const FormatException('Duplicate private code');
        }
      }
      if (expires <= clock()) throw const ClientFailure(401);
      _sessionExpiresAt = expires;
      _sources = sources;
      _unassigned = unassigned;
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
