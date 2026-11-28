import 'dart:convert';

/// Exact transfer request shapes. This gate is not authorization, the server
/// independently authenticates owner, device, generation and each UV ceremony.
bool transferRequestAllowed(String path, Map<String, dynamic> body) {
  final keys = body.keys.toSet();
  bool exact(Set<String> expected) =>
      keys.length == expected.length && keys.containsAll(expected);
  if (body['protocol'] != 2) return false;
  final valid = switch (path) {
    '/v1/manage/totp/batch-begin' => exact({'protocol', 'batchNonce', 'items'}),
    '/v1/manage/totp/batch-finish' => exact({
      'protocol',
      'admissionId',
      'batchNonce',
      'items',
      'token',
      'response',
    }),
    '/v1/manage/totp/batch-outcome' =>
      exact({'protocol', 'admissionId', 'batchNonce', 'fence'}) &&
          body['fence'] == true,
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
