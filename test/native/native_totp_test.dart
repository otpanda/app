import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/totp_enrollment.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';

class _Ks implements NativeKeystore {
  @override
  Future<Uint8List> ensureKey() async =>
      Uint8List.fromList([4, ...List.filled(64, 1)]);
  @override
  Future<Uint8List> beginNewKey() => ensureKey();
  @override
  Future<void> commitNewKey() async {}
  @override
  Future<void> discardNewKey() async {}
  @override
  Future<bool> hasPendingKey() async => false;
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async =>
      Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
  @override
  Future<void> deleteKey() async {}
}

class _St implements NativeSecureStore {
  String? id = 'DEV';
  @override
  Future<String?> readDeviceId() async => id;
  @override
  Future<void> writeDeviceId(String v) async => id = v;
  @override
  Future<void> clear() async => id = null;
}

class _Br implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _G implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

class _Pk implements PasskeyAssertionSource {
  _Pk(this.available, this.result);
  @override
  final bool available;
  String? result;
  final requests = <String>[];
  @override
  Future<String?> get(String j) async {
    requests.add(j);
    return result;
  }
}

String _tok() => 'otpda_${'A' * 55}';
const _assertion =
    '{"id":"cid","rawId":"cid","type":"public-key","response":{"clientDataJSON":"cd","authenticatorData":"ad","signature":"sg","userHandle":null},"extra":1}';

void main() {
  late List<String> calls;
  late List<Map<String, dynamic>> bodies;
  late int finishStatus;
  const now = 1000000;

  Future<NativeSessionController> signedIn() async {
    final c = NativeSessionController(
      NativeAuth(
        post: (p, b) async {
          if (p == '/auth/native/challenge') {
            return (
              status: 200,
              body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
            );
          }
          if (p == '/auth/native/renew') {
            return (
              status: 200,
              body: {'access': 'tok', 'access_expires_at': 9999999999999},
            );
          }
          return (status: 404, body: null);
        },
        keystore: _Ks(),
        browser: _Br(),
        google: _G(),
        store: _St(),
        apiOrigin: 'https://api.example',
        launchUrl: (c, s) => Uri.parse('https://x/'),
      ),
    );
    await c.start();
    return c;
  }

  NativeSessionBridge bridgeFor(NativeSessionController c, _Pk? pk) =>
      NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async {
          calls.add('$m $p $bearer');
          bodies.add(
            body == null ? {} : jsonDecode(body) as Map<String, dynamic>,
          );
          if (p.endsWith('/begin')) {
            return SessionResponse(
              200,
              jsonEncode({
                'token': _tok(),
                'expiresAt': now + 60000,
                'options': {
                  'rpId': 'otpanda.github.io',
                  'userVerification': 'required',
                  'challenge': 'C' * 43,
                  'allowCredentials': [
                    {'id': 'abc_-'},
                  ],
                },
              }),
            );
          }
          return SessionResponse(finishStatus, '{"entryId":"entry-1"}');
        },
        passkeys: pk,
        now: () => now,
      );

  test(
    'transfer post has exact gate and never retries finish after401',
    () async {
      final c = await signedIn();
      var requests = 0;
      final b = NativeSessionBridge(c, (
        m,
        p, {
        body,
        query,
        required bearer,
      }) async {
        requests++;
        return const SessionResponse(401, '{}');
      });
      expect(
        (await b.transferPost('/v1/manage/totp/batch-finish', {
          'batchNonce': 'A' * 32,
          'items': [],
          'token': 'x',
          'response': {},
        })).status,
        401,
      );
      expect(requests, 1);
      expect(
        () => b.transferPost('/v1/manage/totp/batch-finish?x=1', {}),
        throwsStateError,
      );
      expect(
        () => b.transferPost('/v1/manage/totp/export-begin', {
          'ephemeralKey': 'x',
          'url': 'https://example.invalid',
        }),
        throwsStateError,
      );
      expect(requests, 1);
    },
  );

  test('batch uses exact repeated entry query, GET, no body and renewed native bearer', () async {
    final c = await signedIn();
    String? method, path, token, requestBody;
    Map<String, String>? requestQuery;
    final b = NativeSessionBridge(c, (
      m,
      p, {
      body,
      query,
      required bearer,
    }) async {
      method = m;
      path = p;
      token = bearer;
      requestBody = body;
      requestQuery = query;
      return const SessionResponse(200, '{}');
    });
    await b.totpBatch(['a/b', 'entry+two'], windowSeconds: 600);
    expect(method, 'GET');
    expect(token, 'tok');
    expect(requestBody, null);
    expect(requestQuery, null);
    final u = Uri.parse(path!);
    expect(u.path, '/v1/manage/totp-codes');
    expect(u.queryParametersAll, {
      'entry': ['a/b', 'entry+two'],
      'window': ['600'],
    });
    expect(
      () => b.totpBatch(['a', 'a'], windowSeconds: 600),
      throwsArgumentError,
    );
  });

  setUp(() {
    calls = [];
    bodies = [];
    finishStatus = 201;
  });

  test(
    'add TOTP: begin, OS passkey assertion, finish, returns entry id',
    () async {
      final pk = _Pk(true, _assertion);
      final b = bridgeFor(await signedIn(), pk);
      expect(b.canAddTotp, isTrue);
      expect(await b.addTotp('L', 'a@x.test', 'JBSWY3DPEHPK3PXP'), 'entry-1');
      expect(calls, [
        'POST /v1/manage/totp/begin tok',
        'POST /v1/manage/totp tok',
      ]);
      final req = jsonDecode(pk.requests.single) as Map;
      expect(req['rpId'], 'otpanda.github.io');
      expect(req['userVerification'], 'required');
      expect(req['timeout'], 60000);
      expect(req['allowCredentials'], [
        {'type': 'public-key', 'id': 'abc_-'},
      ]);
      final fin = bodies.last;
      expect(fin['token'], _tok());
      expect(fin['label'], 'L');
      expect(fin['secret'], 'JBSWY3DPEHPK3PXP');
      final r = fin['response'] as Map;
      expect(r['clientExtensionResults'], isEmpty);
      expect(r.containsKey('extra'), isFalse);
      expect(bodies.first.containsKey('token'), isFalse);
    },
  );

  test('no provider hides the action and refuses before any request', () async {
    for (final pk in [null, _Pk(false, null)]) {
      final b = bridgeFor(await signedIn(), pk);
      expect(b.canAddTotp, isFalse);
      await expectLater(b.addTotp('L', 'a', 'S'), throwsStateError);
    }
    expect(calls, isEmpty);
  });

  test('cancel never finishes; failed finish and bad options throw', () async {
    final cancel = _Pk(true, null);
    final b = bridgeFor(await signedIn(), cancel);
    await expectLater(b.addTotp('L', 'a', 'S'), throwsStateError);
    expect(calls.length, 1);
    finishStatus = 403;
    final fail = bridgeFor(await signedIn(), _Pk(true, _assertion));
    await expectLater(
      fail.addTotp('L', 'a', 'S'),
      throwsA(isA<ClientFailure>()),
    );
    expect(
      () => passkeyRequestJson({
        'token': 'x',
        'options': {},
        'expiresAt': now + 1,
      }, nowMs: now),
      throwsA(isA<PasskeyException>()),
    );
    expect(
      () => passkeyRequestJson({
        'token': _tok(),
        'expiresAt': now + 500000,
        'options': {
          'rpId': 'otpanda.github.io',
          'userVerification': 'required',
          'challenge': 'C' * 43,
          'allowCredentials': [],
        },
      }, nowMs: now),
      throwsA(isA<PasskeyException>()),
    );
    expect(
      () => passkeyAssertionBody('{"type":"public-key"}'),
      throwsA(isA<PasskeyException>()),
    );
  });

  testWidgets(
    'QR scan prefills the shared Add dialog and saves through native step-up',
    (t) async {
      final pk = _Pk(true, _assertion);
      final b = bridgeFor(await signedIn(), pk);
      String? saved;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async => saved = await addTotpDialog(
                c,
                b,
                camera: (onText, onError) {
                  scheduleMicrotask(
                    () => onText(
                      'otpauth://totp/Example:a@x.test?secret=JBSWY3DPEHPK3PXP&issuer=Example',
                    ),
                  );
                  return const SizedBox.expand();
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.pumpAndSettle();
      await t.tap(find.text('Verify and add'));
      await t.pumpAndSettle();
      expect(saved, 'entry-1');
      expect(bodies.first['label'], 'Example');
      expect(bodies.first['secret'], startsWith('otpauth://totp/'));
      expect(calls, [
        'POST /v1/manage/totp/begin tok',
        'POST /v1/manage/totp tok',
      ]);
    },
  );
}
