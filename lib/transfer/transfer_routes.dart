import 'dart:convert';

/// Exact transfer request shapes. This gate is not authorization, the server
/// independently authenticates owner, device, generation and each UV ceremony.
bool transferRequestAllowed(String path, Map<String, dynamic> body) {
  final keys = body.keys.toSet();
  bool exact(Set<String> expected) =>
      keys.length == expected.length && keys.containsAll(expected);
  final valid = switch (path) {
    '/v1/manage/totp/batch-begin' => exact({'batchNonce', 'items'}),
    '/v1/manage/totp/batch-finish' => exact({
      'batchNonce',
      'items',
      'token',
      'response',
    }),
    '/v1/manage/totp/batch-outcome' => exact({'batchNonce'}),
    '/v1/manage/totp/export-begin' =>
      exact({'ephemeralKey'}) || exact({'ephemeralKey', 'entryIds'}),
    '/v1/manage/totp/export-finish' => exact({
      'ephemeralKey',
      'entries',
      'token',
      'response',
    }),
    _ => false,
  };
  if (!valid) return false;
  try {
    return utf8.encode(jsonEncode(body)).length <=
        (path.contains('batch-') ? 65536 : 32768);
  } catch (_) {
    return false;
  }
}
