import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_manage_settings.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/recovery_contract.dart';

class _Pk implements PasskeyAssertionSource {
  _Pk(this.out);
  String? out;
  final requests = <String>[];
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async {
    requests.add(requestJson);
    return out;
  }
}

const _asserted =
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","authenticatorData":"a","signature":"s","userHandle":null}}';
String _tok(String c) => 'otpda_${c * 55}';

void main() {
  late int now;
  late List<(String, String, Map<String, dynamic>?)> sent;
  late Map<String, ({int status, Map<String, dynamic>? body})> replies;
  late _Pk pk;

  NativeManageSettings make() => NativeManageSettings(
    request: (m, p, b) async {
      sent.add((m, p, b));
      final r = replies[p];
      if (r == null) throw Exception('network');
      return r;
    },
    passkeys: pk,
    nowMs: () => now,
  );

  Map<String, dynamic> begin({String exp = 'expiresAt', int add = 60000}) => {
    'token': _tok('T'),
    exp: now + add,
    'options': {
      'rpId': 'otpanda.github.io',
      'userVerification': 'required',
      'challenge': 'A' * 43,
      'allowCredentials': [
        {'id': 'c1'},
      ],
    },
  };

  setUp(() {
    now = DateTime.now().millisecondsSinceEpoch;
    sent = [];
    pk = _Pk(_asserted);
    replies = {};
  });

  test('status reads use GET with no body', () async {
    replies['/v1/manage/recovery/status'] = (status: 200, body: {'a': 1});
    replies['/v1/manage/security/status'] = (status: 200, body: {'b': 2});
    final m = make();
    expect(await m.recoveryStatus(), {'a': 1});
    expect(await m.securityStatus(), {'b': 2});
    expect(sent.every((e) => e.$1 == 'GET' && e.$3 == null), isTrue);
  });

  test(
    'recovery change: begin, one passkey, finish with same body and token',
    () async {
      replies['/v1/manage/recovery/begin'] = (status: 200, body: begin());
      replies['/v1/manage/recovery/finish'] = (status: 200, body: {});
      await make().recoveryChange(
        const RecoveryChange(RecoveryKind.passkeyRevoke, target: 'cred'),
      );
      expect(pk.requests.length, 1);
      final b = sent[0].$3!, f = sent[1].$3!;
      expect(b, {'kind': 'passkey-revoke', 'target': 'cred'});
      expect(f['kind'], 'passkey-revoke');
      expect(f['target'], 'cred');
      expect(f['token'], _tok('T'));
      expect((f['response'] as Map)['id'], 'i');
    },
  );

  test(
    'email-escape-on needs the accepted warning; revoke needs a target',
    () async {
      final m = make();
      await expectLater(
        m.recoveryChange(const RecoveryChange(RecoveryKind.emailEscapeOn)),
        throwsA(isA<RecoveryRefused>()),
      );
      await expectLater(
        m.recoveryChange(const RecoveryChange(RecoveryKind.sessionRevoke)),
        throwsA(isA<RecoveryRefused>()),
      );
      expect(sent, isEmpty);
    },
  );

  test('dismissed prompt is refused and finish is never sent', () async {
    pk.out = null;
    replies['/v1/manage/recovery/begin'] = (status: 200, body: begin());
    await expectLater(
      make().recoveryChange(const RecoveryChange(RecoveryKind.googleUnlink)),
      throwsA(isA<RecoveryRefused>()),
    );
    expect(sent.any((e) => e.$2.endsWith('finish')), isFalse);
  });

  test('finish 5xx or network loss is unknown; 4xx is refused', () async {
    Future<Object?> run(({int status, Map<String, dynamic>? body})? fin) async {
      replies = {'/v1/manage/recovery/begin': (status: 200, body: begin())};
      if (fin != null) replies['/v1/manage/recovery/finish'] = fin;
      try {
        await make().recoveryChange(
          const RecoveryChange(RecoveryKind.emailEscapeOff),
        );
        return null;
      } catch (e) {
        return e;
      }
    }

    expect(await run((status: 500, body: null)), isA<RecoveryOutcomeUnknown>());
    expect(await run(null), isA<RecoveryOutcomeUnknown>());
    expect(await run((status: 403, body: {})), isA<RecoveryRefused>());
  });

  test(
    'a begin for another rp or a long expiry is rejected before the prompt',
    () async {
      final bad = begin();
      (bad['options'] as Map)['rpId'] = 'evil.example';
      replies['/v1/manage/security/begin'] = (status: 200, body: bad);
      await expectLater(make().setExtraVerification(true), throwsStateError);
      replies['/v1/manage/security/begin'] = (
        status: 200,
        body: begin(add: 600000),
      );
      await expectLater(make().setExtraVerification(true), throwsStateError);
      expect(pk.requests, isEmpty);
    },
  );

  test('security toggle sends enabled and warningAccepted', () async {
    replies['/v1/manage/security/begin'] = (status: 200, body: begin());
    replies['/v1/manage/security/finish'] = (status: 200, body: {});
    await make().setExtraVerification(false);
    expect(sent[0].$3, {'enabled': false, 'warningAccepted': true});
    expect(sent[1].$3!['enabled'], false);
    expect(sent[1].$3!['token'], _tok('T'));
  });

  test('deny works; there is no approve call', () async {
    replies['/v1/manage/security/deny'] = (status: 200, body: {});
    await make().denyPending('p1');
    expect(sent.single.$2, '/v1/manage/security/deny');
    expect(sent.single.$3, {'pendingId': 'p1'});
  });

  test('rename validates the label and needs ok:true', () async {
    replies['/v1/manage/passkey/rename'] = (status: 200, body: {'ok': true});
    final m = make();
    await m.renamePasskey('c1', '  My phone ');
    expect(sent.single.$3, {'credentialId': 'c1', 'label': 'My phone'});
    await m.renamePasskey('c1', null);
    expect(sent.last.$3!['label'], isNull);
    await expectLater(
      m.renamePasskey('c1', 'x' * 41),
      throwsA(isA<RecoveryRefused>()),
    );
    await expectLater(
      m.renamePasskey('c1', 'a\nb'),
      throwsA(isA<RecoveryRefused>()),
    );
    replies['/v1/manage/passkey/rename'] = (status: 200, body: {});
    await expectLater(
      m.renamePasskey('c1', 'ok'),
      throwsA(isA<RecoveryOutcomeUnknown>()),
    );
  });

  test(
    'google link: ticket shape, then begin/finish with snake expires_at',
    () async {
      replies['/v1/manage/google/link/ticket'] = (
        status: 200,
        body: {'ticket': 'T' * 43, 'expiresAt': now + 1000},
      );
      final m = make();
      final t = await m.googleLinkTicket('A' * 43);
      expect(t, 'T' * 43);
      await expectLater(m.googleLinkTicket('short'), throwsStateError);
      replies['/v1/manage/google/link/begin'] = (
        status: 200,
        body: begin(exp: 'expires_at'),
      );
      replies['/v1/manage/google/link/finish'] = (
        status: 200,
        body: {'status': 'linked'},
      );
      await m.googleLinkFinish(_tok('K'));
      final f = sent.last.$3!;
      expect(f['continuation'], _tok('K'));
      expect(f['token'], _tok('T'));
      replies['/v1/manage/google/link/finish'] = (
        status: 200,
        body: {'status': 'x'},
      );
      await expectLater(
        m.googleLinkFinish(_tok('K')),
        throwsA(isA<RecoveryOutcomeUnknown>()),
      );
    },
  );
}
