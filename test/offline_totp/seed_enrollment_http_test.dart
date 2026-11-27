import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/offline_totp/seed_enrollment_coordinator.dart';
import 'package:otpanda_client/offline_totp/seed_enrollment_http.dart';
import 'package:otpanda_client/offline_totp/seed_status_coordinator.dart';

typedef R = ({int status, Map<String, dynamic>? body});

class FakeStatus implements SeedStatusTransport {
  final replies = <SeedStatusResponse>[];
  final sent = <(String, Map<String, Object>)>[];
  @override
  Future<SeedStatusResponse> post(String path, Map<String, Object> body) async {
    sent.add((path, body));
    return replies.removeAt(0);
  }
}

class FakeSource implements PasskeyAssertionSource {
  FakeSource(this.reply);
  String? reply;
  String? request;
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async {
    request = requestJson;
    return reply;
  }
}

void main() {
  final fx = jsonDecode(
    File('test/offline_totp/fixtures/seed_enrollment_http.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  Map<String, dynamic> m(String k, String s) =>
      Map<String, dynamic>.from((fx[k] as Map)[s] as Map);
  final jwk = {'kty': 'EC', 'crv': 'P-256', 'x': 'x' * 43, 'y': 'y' * 43};
  final sent = <(String, Map<String, dynamic>)>[];
  late R Function(String) reply;
  late FakeStatus status;
  late SeedEnrollmentHttp api;
  setUp(() {
    sent.clear();
    status = FakeStatus();
    reply = (_) => (status: 500, body: null);
    api = SeedEnrollmentHttp(
      post: (p, b) async {
        sent.add((p, b));
        return reply(p);
      },
      statusTransport: status,
      signStatus: ({
        required owner,
        required keyId,
        required challenge,
        required expiresAt,
      }) async => 'g' * 86,
    );
  });

  test('request fixtures are allowed and exact', () {
    for (final op in [
      'context',
      'stepup-begin',
      'enroll-finish',
      'status-begin',
      'status-finish',
    ]) {
      expect(seedSyncRequestAllowed(op, m(op, 'request')), isTrue, reason: op);
    }
    expect(seedSyncRequestAllowed('context', {'x': 1}), isFalse);
    expect(
      seedSyncRequestAllowed('stepup-begin', {
        ...m('stepup-begin', 'request'),
        'extra': 1,
      }),
      isFalse,
    );
    expect(
      seedSyncRequestAllowed('snapshot-begin', {'epoch': 1, 'keyId': 'a' * 32}),
      isFalse,
    );
    expect(seedSyncRequestAllowed('list', {}), isFalse);
  });

  test('context parses strictly', () async {
    reply = (_) => (status: 200, body: m('context', 'response'));
    expect(await api.context(), 3);
    expect(sent.single.$1, '/v1/manage/seed-sync/context');
    expect(sent.single.$2, isEmpty);
    for (final bad in [
      {'generation': -1},
      {'generation': '3'},
      {'generation': 3, 'x': 1},
      <String, dynamic>{},
    ]) {
      reply = (_) => (status: 200, body: bad);
      await expectLater(
        api.context(),
        throwsA(isA<SeedEnrollmentHttpException>()),
      );
    }
    reply = (_) => (status: 409, body: null);
    await expectLater(
      api.context(),
      throwsA(isA<SeedEnrollmentHttpException>()),
    );
  });

  test(
    'step-up then enroll-begin then finish, with the passkey body',
    () async {
      reply = (_) => (status: 200, body: m('stepup-begin', 'response'));
      final s = await api.stepUpBegin(
        installId: 'I' * 22,
        keyId: 'a' * 32,
        publicJwk: jwk,
      );
      expect(s.token, 'otpda_${'s' * 55}');
      expect(sent.last.$1, '/v1/manage/seed-sync/stepup-begin');
      expect(sent.last.$2.keys.toSet(), {'installId', 'keyId', 'publicJwk'});

      final src = FakeSource(
        jsonEncode({
          'type': 'public-key',
          'id': 'cred1',
          'rawId': 'cred1',
          'response': {
            'clientDataJSON': 'a',
            'authenticatorData': 'b',
            'signature': 'c',
            'userHandle': null,
          },
        }),
      );
      final nowMs = 1000 - 60000;
      final asserter = SeedPasskeyStepUp(src, nowMs: () => nowMs);
      final assertion = await asserter.assertStepUp(s.options);
      expect(jsonDecode(src.request!)['rpId'], 'otpanda.github.io');

      reply = (_) => (status: 200, body: m('enroll-begin', 'response'));
      final c = await api.enrollBegin(
        installId: 'I' * 22,
        keyId: 'a' * 32,
        publicJwk: jwk,
        assertion: assertion,
        token: s.token,
      );
      expect(c.generation, 3);
      expect(c.ownerId, 'own_1');
      expect(sent.last.$2.keys.toSet(), {
        'installId',
        'keyId',
        'publicJwk',
        'response',
        'token',
      });

      reply = (_) => (status: 200, body: m('enroll-finish', 'response'));
      expect(
        await api.enrollFinish(signature: 'g' * 86, token: c.token),
        isTrue,
      );
      expect(sent.last.$2.keys.toSet(), {'signature', 'token'});
      // single use: a second finish with the same token never leaves the device
      final n = sent.length;
      await expectLater(
        api.enrollFinish(signature: 'g' * 86, token: c.token),
        throwsStateError,
      );
      expect(sent.length, n);
    },
  );

  test('passkey cancel and wrong options stop before enroll', () async {
    final s = FakeSource(null);
    await expectLater(
      SeedPasskeyStepUp(
        s,
        nowMs: () => 0,
      ).assertStepUp(m('stepup-begin', 'response')['options']),
      throwsA(isA<PasskeyException>()),
    );
    await expectLater(
      SeedPasskeyStepUp(s).assertStepUp('x'),
      throwsA(isA<PasskeyException>()),
    );
  });

  test('stepUpBegin rejects malformed responses and bad inputs', () async {
    final good = m('stepup-begin', 'response');
    for (final bad in [
      {...good, 'token': 'nope'},
      {...good, 'options': 'x'},
      {...good, 'expiresAt': '1'},
      {...good, 'extra': 1},
    ]) {
      reply = (_) => (status: 200, body: bad);
      await expectLater(
        api.stepUpBegin(installId: 'I' * 22, keyId: 'a' * 32, publicJwk: jwk),
        throwsA(isA<SeedEnrollmentHttpException>()),
      );
    }
    expect(
      () => api.stepUpBegin(installId: 'I' * 22, keyId: 'ABC', publicJwk: jwk),
      throwsArgumentError,
    );
    expect(
      () => api.stepUpBegin(
        installId: 'I' * 22,
        keyId: 'a' * 32,
        publicJwk: {...jwk, 'd': 'x'},
      ),
      throwsArgumentError,
    );
  });

  test('enrollBegin rejects echo mismatch and malformed challenges', () async {
    final good = m('enroll-begin', 'response');
    Map<String, dynamic> withC(Map<String, dynamic> o) => {
      'token': good['token'],
      'challenge': {...(good['challenge'] as Map<String, dynamic>), ...o},
    };
    for (final bad in [
      withC({'keyId': 'b' * 32}),
      withC({'installId': 'J' * 22}),
      withC({'actionDigest': 'zz'}),
      withC({'challenge': 'short'}),
      withC({'generation': -1}),
      withC({'extra': 1}),
      {'token': 'bad', 'challenge': good['challenge']},
    ]) {
      reply = (_) => (status: 200, body: bad);
      await expectLater(
        api.enrollBegin(
          installId: 'I' * 22,
          keyId: 'a' * 32,
          publicJwk: jwk,
          assertion: <String, dynamic>{},
          token: 'otpda_${'s' * 55}',
        ),
        throwsA(isA<SeedEnrollmentHttpException>()),
      );
    }
    reply = (_) => (status: 409, body: m('errors', 'conflict')['body']);
    await expectLater(
      api.enrollBegin(
        installId: 'I' * 22,
        keyId: 'a' * 32,
        publicJwk: jwk,
        assertion: <String, dynamic>{},
        token: 'otpda_${'s' * 55}',
      ),
      throwsA(isA<SeedEnrollmentHttpException>()),
    );
  });

  test(
    'finish: only the exact keyId body is success; failures are false',
    () async {
      reply = (_) => (status: 200, body: m('enroll-begin', 'response'));
      final c = await api.enrollBegin(
        installId: 'I' * 22,
        keyId: 'a' * 32,
        publicJwk: jwk,
        assertion: <String, dynamic>{},
        token: 'otpda_${'s' * 55}',
      );
      for (final r in <R>[
        (status: 409, body: null),
        (status: 200, body: {'keyId': 'b' * 32}),
        (status: 200, body: {'keyId': 'a' * 32, 'x': 1}),
        (status: 200, body: null),
        (status: 503, body: null),
      ]) {
        reply = (_) => r;
        expect(
          await api.enrollFinish(signature: 'g' * 86, token: c.token),
          isFalse,
        );
        reply = (_) => (status: 200, body: m('enroll-begin', 'response'));
        await api.enrollBegin(
          installId: 'I' * 22,
          keyId: 'a' * 32,
          publicJwk: jwk,
          assertion: <String, dynamic>{},
          token: 'otpda_${'s' * 55}',
        );
      }
      // a transport error propagates (unknown), it is not turned into false
      reply = (_) => throw const SocketException('lost');
      await expectLater(
        api.enrollFinish(signature: 'g' * 86, token: c.token),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('keyStatus maps states; every odd answer is unknown', () async {
    SeedStatusResponse ok(Object o) => SeedStatusResponse(200, jsonEncode(o));
    for (final (s, want) in [
      ('active', SeedServerKeyState.active),
      ('key-revoked', SeedServerKeyState.revoked),
      ('generation-changed', SeedServerKeyState.generationChanged),
      ('other', SeedServerKeyState.unknown),
    ]) {
      status.replies
        ..add(ok(m('status-begin', 'response')))
        ..add(ok({'state': s}));
      expect(
        await api.keyStatus(owner: 'own_1', keyId: 'a' * 32),
        want,
        reason: s,
      );
    }
    expect(status.sent.first.$1, '/v1/manage/seed-sync/status-begin');
    expect(status.sent[1].$2.keys.toSet(), {'token', 'signature'});
    expect(sent, isEmpty, reason: 'status never uses the bearer client');
    // wrong echoed key, 409, garbage, extra keys
    final b = m('status-begin', 'response');
    for (final bad in [
      [
        ok({
          ...b,
          'challenge': {...(b['challenge'] as Map), 'keyId': 'b' * 32},
        }),
      ],
      [const SeedStatusResponse(409, '{}')],
      [const SeedStatusResponse(200, 'not json')],
      [
        ok({...b, 'x': 1}),
      ],
      [ok(b), const SeedStatusResponse(409, '{}')],
      [
        ok(b),
        ok({'state': 'active', 'x': 1}),
      ],
    ]) {
      status.replies
        ..clear()
        ..addAll(bad);
      expect(
        await api.keyStatus(owner: 'own_1', keyId: 'a' * 32),
        SeedServerKeyState.unknown,
      );
    }
  });
}
