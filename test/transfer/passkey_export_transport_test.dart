import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/transfer/passkey_export_transport.dart';
import 'package:otpanda_client/transfer/export_plan.dart';
import 'package:otpanda_client/transfer/sealed_export_source.dart';
import 'package:otpanda_client/native/native_passkey.dart';

class Pk implements PasskeyAssertionSource {
  @override
  bool available = true;
  int prompts = 0;
  void Function()? during;
  @override
  Future<String?> get(String r) async {
    prompts++;
    during?.call();
    return '{"id":"cid","rawId":"cid","type":"public-key","response":{"clientDataJSON":"cd","authenticatorData":"ad","signature":"sg","userHandle":null}}';
  }
}

Map<String, dynamic> challenge() => {
  'ownerId': 'owner',
  'deviceId': 'dev',
  'generation': 2,
  'token': 'otpda_${'A' * 55}',
  'expiresAt': 1060000,
  'options': {
    'challenge': 'A' * 43,
    'rpId': 'otpanda.github.io',
    'userVerification': 'required',
    'allowCredentials': [
      {'id': 'Y2lk'},
    ],
  },
  'entries': [
    {
      'entryId': 'one',
      'version': 'a' * 64,
      'label': 'raw: label',
      'account': ' acct ',
      'issuer': null,
      'catalogId': 'x',
    },
  ],
  'unavailable': <String>[],
};
void main() {
  test(
    'one native ceremony, exact frozen set echoed and one-shot finish',
    () async {
      final pk = Pk(), paths = <String>[];
      final bodies = <Map<String, dynamic>>[];
      final t = PasskeyExportTransport(
        ownerId: 'owner',
        deviceId: 'dev',
        passkeys: pk,
        current: () async => true,
        nowMs: () => 1000000,
        post: (path, b) async {
          paths.add(path);
          bodies.add(b);
          return (
            status: 200,
            body: path.endsWith('begin')
                ? challenge()
                : <String, dynamic>{'serverPublicKey': 'point', 'entries': []},
          );
        },
      );
      final begin = await t.begin(ephemeralKey: 'ephemeral');
      expect(begin.entries.single.account, ' acct ');
      await t.finish(begin: begin, ephemeralKey: 'ephemeral');
      expect(pk.prompts, 1);
      expect(bodies.last['entries'], [
        {'entryId': 'one', 'version': 'a' * 64},
      ]);
      expect(
        () => t.finish(begin: begin, ephemeralKey: 'ephemeral'),
        throwsA(isA<ExportRejectedException>()),
      );
      expect(paths.length, 2);
    },
  );
  test('owner/background fence during prompt prevents finish', () async {
    var current = true;
    final pk = Pk()..during = (() => current = false);
    final paths = <String>[];
    final t = PasskeyExportTransport(
      ownerId: 'owner',
      deviceId: 'dev',
      passkeys: pk,
      current: () async => current,
      nowMs: () => 1000000,
      post: (path, b) async {
        paths.add(path);
        return (status: 200, body: challenge());
      },
    );
    final begin = await t.begin(ephemeralKey: 'ephemeral');
    expect(
      () => t.finish(begin: begin, ephemeralKey: 'ephemeral'),
      throwsA(isA<ExportAuthException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(paths.length, 1);
  });
  test('duplicate frozen ids refused before passkey', () async {
    final pk = Pk(), b = challenge();
    (b['entries'] as List).add((b['entries'] as List).first);
    final t = PasskeyExportTransport(
      ownerId: 'owner',
      deviceId: 'dev',
      passkeys: pk,
      current: () async => true,
      nowMs: () => 1000000,
      post: (p, bod) async => (status: 200, body: b),
    );
    expect(
      () => t.begin(ephemeralKey: 'x'),
      throwsA(isA<ExportRejectedException>()),
    );
    expect(pk.prompts, 0);
  });
}
