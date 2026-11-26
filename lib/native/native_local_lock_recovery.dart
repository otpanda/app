import 'dart:convert';

import '../session_contract.dart';
import 'native_passkey.dart';

typedef LocalRecoveryPost = Future<SessionResponse> Function(
  String path,
  String body,
);

/// A fresh exact-action ceremony. It cannot renew sessions or authorize account changes.
class NativeLocalLockRecovery {
  NativeLocalLockRecovery({
    required this.post,
    required this.passkeys,
    required this.deviceId,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final LocalRecoveryPost post;
  final PasskeyAssertionSource passkeys;
  final String? Function() deviceId;
  final int Function() now;
  Future<bool> verify(String intent, String generation) async {
    if (!passkeys.available ||
        !{'local-unlock-once', 'local-lock-disable'}.contains(intent)) {
      return false;
    }
    final device = deviceId();
    if (device == null) return false;
    Map<String, dynamic> decode(SessionResponse r) {
      if (r.status != 200) throw StateError('Verification unavailable');
      final v = jsonDecode(r.body);
      if (v is! Map<String, dynamic>) throw const FormatException();
      return v;
    }

    final begin = decode(
      await post(
        '/v1/manage/local-lock/begin',
        jsonEncode({'intent': intent, 'lockGeneration': generation}),
      ),
    );
    final assertion = await passkeys.get(
      passkeyRequestJson(begin, nowMs: now()),
    );
    if (assertion == null || deviceId() != device) return false;
    final finish = decode(
      await post(
        '/v1/manage/local-lock/finish',
        jsonEncode({
          'intent': intent,
          'lockGeneration': generation,
          'token': begin['token'],
          'response': passkeyAssertionBody(assertion),
        }),
      ),
    );
    return deviceId() == device &&
        finish['intent'] == intent &&
        finish['lockGeneration'] == generation &&
        finish['deviceId'] == device &&
        finish['generation'] is int;
  }
}
