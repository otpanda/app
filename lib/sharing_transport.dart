import 'dart:convert';

import 'management_contract.dart';
import 'session_contract.dart';

/// Sharing management is an explicit capability. No arbitrary management URLs,
/// machine-token reads, automatic retry or stored invite token.
class BoundSharingTransport implements ManagementTransport {
  const BoundSharingTransport({required this.current, required this.send});
  final Future<bool> Function() current;
  final Future<SessionResponse> Function(String, Map<String, Object?>) send;
  static const paths = {
    '/v1/manage/machine/entries/list',
    '/v1/manage/machine/profile/create',
    '/v1/manage/machine/profile/revoke',
    '/v1/manage/machine/profiles/list',
    '/v1/manage/machine/token/create',
    '/v1/manage/machine/token/revoke',
    '/v1/manage/sharing/contacts/list',
    '/v1/manage/sharing/contacts/remove',
    '/v1/manage/sharing/grant/create',
    '/v1/manage/sharing/grant/revoke',
    '/v1/manage/sharing/grant/update',
    '/v1/manage/sharing/invite/create',
    '/v1/manage/sharing/invite/list',
    '/v1/manage/sharing/invite/revoke',
  };
  @override
  Future<SessionResponse> request(
    String path,
    String method,
    Map<String, Object?>? body,
  ) async {
    if (method != 'POST' ||
        !paths.contains(path) ||
        body == null ||
        utf8.encode(jsonEncode(body)).length > 4096) {
      throw StateError('Sharing request required');
    }
    if (!await current()) return const SessionResponse(503, '{}');
    final r = await send(path, body);
    return await current() ? r : const SessionResponse(503, '{}');
  }
}
