import 'dart:convert';

import 'session_contract.dart';

/// The platform supplies session authentication and CSRF for non-GET requests.
/// Never attach bearer automation tokens to this transport.
abstract interface class ManagementTransport {
  Future<SessionResponse> request(
    String path,
    String method,
    Map<String, Object?>? body,
  );
}

class MutationUnconfirmed implements Exception {
  const MutationUnconfirmed();
  @override
  String toString() =>
      'Could not confirm the change. Refresh before trying again; it may already have happened.';
}

class ManagementClient {
  final ManagementTransport transport;
  const ManagementClient(this.transport);

  Future<Map<String, dynamic>> _mutate(
    String path,
    String method,
    Map<String, Object?> body, {
    int status = 200,
  }) async {
    SessionResponse response;
    try {
      response = await transport.request(path, method, body);
    } catch (_) {
      throw const MutationUnconfirmed();
    }
    if (response.status == 401 ||
        response.status == 403 ||
        response.status == 400 ||
        response.status == 404 ||
        response.status == 429) {
      throw ClientFailure(response.status);
    }
    // An HTTP failure or a malformed success can occur after a write committed.
    // This client never retries a mutation automatically.
    if (response.status != status || response.body.length > 65536) {
      throw const MutationUnconfirmed();
    }
    try {
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) throw const FormatException();
      return body;
    } catch (_) {
      throw const MutationUnconfirmed();
    }
  }

  Future<String> createEntry({
    required String serviceId,
    required String label,
    String? account,
  }) async {
    final body = <String, Object?>{
      'serviceId': _text(serviceId, 128),
      'label': _text(label, 120),
    };
    if (account != null && account.trim().isNotEmpty) {
      body['accountName'] = _text(account, 120);
    }
    final response = await _mutate(
      '/v1/manage/entries',
      'POST',
      body,
      status: 201,
    );
    final id = response['entryId'];
    if (id is! String || id.isEmpty || id.length > 256) {
      throw const MutationUnconfirmed();
    }
    return id;
  }

  Future<void> renameEntry(String entryId, String label) => _ok(
    '/v1/manage/entries',
    'PATCH',
    {'entryId': _text(entryId, 256), 'label': _text(label, 120)},
  );
  Future<void> updateAccount(String entryId, String? account) =>
      _ok('/v1/manage/entry-account', 'PATCH', {
        'entryId': _text(entryId, 256),
        'accountName': account == null || account.trim().isEmpty
            ? null
            : _text(account, 120),
      });
  Future<void> deleteEntry(String entryId) =>
      _ok('/v1/manage/entries', 'DELETE', {'entryId': _text(entryId, 256)});
  Future<void> revokeSource(String sourceId) => _ok(
    '/v1/manage/revoke-source',
    'POST',
    {'sourceId': _text(sourceId, 256)},
  );
  Future<void> assignCode({
    required String sourceId,
    required String eventId,
    required String entryId,
  }) => _ok('/v1/manage/confirm-assignment', 'POST', {
    'sourceId': _text(sourceId, 256),
    'eventId': _text(eventId, 256),
    'entryId': _text(entryId, 256),
  });
  Future<void> revokeToken(String tokenId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{12}$').hasMatch(tokenId)) {
      throw ArgumentError('Invalid token identifier');
    }
    return _ok('/v1/manage/tokens/$tokenId', 'DELETE', {});
  }

  Future<void> _ok(
    String path,
    String method,
    Map<String, Object?> body,
  ) async {
    final result = await _mutate(path, method, body);
    if (result['ok'] != true) throw const MutationUnconfirmed();
  }
}

String _text(String value, int max) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > max) {
    throw ArgumentError('Invalid input');
  }
  return trimmed;
}
