import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
  String? id;
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
  bool get available => true;
  @override
  Future<String?> idToken({required String nonce}) async => 'T';
}

class _Pk implements PasskeyAssertionSource, PasskeyCreationSource {
  _Pk({this.created, this.asserted});
  String? created, asserted;
  final requests = <String>[];
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async => asserted;
  @override
  Future<String?> create(String requestJson) async {
    requests.add(requestJson);
    return created;
  }
}

String tok(String c) => 'otpda_${c * 55}';
const _b43 = 'A';
final _challenge = _b43 * 43;

Map<String, dynamic> beginBody(int now, {List excl = const []}) => {
  'token': tok('B'),
  'expiresAt': now + 100000,
  'options': {
    'rp': {'id': 'otpanda.github.io', 'name': 'OTPanda'},
    'user': {'id': 'dXNlcg', 'name': 'a@b.c', 'displayName': 'a@b.c'},
    'challenge': _challenge,
    'authenticatorSelection': {'userVerification': 'required'},
    'excludeCredentials': excl,
  },
};

const _created =
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","attestationObject":"o","transports":["internal"]}}';
const _asserted =
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","authenticatorData":"a","signature":"s","userHandle":"u"}}';

void main() {
  signupTests();
  final now = DateTime.now().millisecondsSinceEpoch;

  test('request JSON: rp, UV, resident key, exclusions limits', () {
    final j = passkeyCreationRequestJson(
      beginBody(now),
      nowMs: now,
      first: true,
    );
    expect(j, contains('"residentKey":"required"'));
    expect(j, contains('"attestation":"none"'));
    expect(
      () => passkeyCreationRequestJson(
        beginBody(
          now,
          excl: [
            {'type': 'public-key', 'id': 'abc'},
          ],
        ),
        nowMs: now,
        first: true,
      ),
      throwsA(isA<PasskeyException>()),
    );
    final b = beginBody(now);
    ((b['options'] as Map)['rp'] as Map)['id'] = 'evil.example';
    expect(
      () => passkeyCreationRequestJson(b, nowMs: now, first: false),
      throwsA(isA<PasskeyException>()),
    );
    expect(
      () => passkeyCreationRequestJson(
        {...beginBody(now), 'expiresAt': now - 1},
        nowMs: now,
        first: false,
      ),
      throwsA(isA<PasskeyException>()),
    );
  });

  group('bridge', () {
    late List<String> calls;
    late List<Map<String, String>> headersSeen;
    late Map<String, int> statuses;
    late Map<String, String> bodies;
    late _Pk pk;

    Future<NativeSessionBridge> bridge({bool grant = true}) async {
      final c = NativeSessionController(
        NativeAuth(
          post: (p, b) async {
            if (p == '/auth/native/google/begin') {
              return (status: 200, body: {'nonce': 'N', 'expires_at': 9});
            }
            if (p == '/auth/native/google/complete') {
              return (
                status: 200,
                body: {
                  'device_id': 'D',
                  'access': 'acc',
                  'access_expires_at': 9999999999999,
                  if (grant) 'enroll_grant': tok('G'),
                },
              );
            }
            return (status: 404, body: null);
          },
          keystore: _Ks(),
          browser: _Br(),
          google: _G(),
          store: _St(),
          apiOrigin: 'https://api.example',
          launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
        ),
      );
      await c.signInWithGoogle();
      SessionResponse reply(String m, String p, String? body) {
        calls.add('$m $p ${body ?? ''}');
        return SessionResponse(statuses[p] ?? 200, bodies[p] ?? '{}');
      }

      return NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async => reply(m, p, body),
        headerRequest: (m, p, {body, required bearer, required headers}) async {
          headersSeen.add(headers);
          return reply(m, p, body);
        },
        passkeys: pk,
        creation: pk,
      );
    }

    setUp(() {
      calls = [];
      headersSeen = [];
      statuses = {};
      bodies = {
        '/v1/manage/first-passkey/finish': '{"status":"registered"}',
        '/v1/manage/passkey/add/register-finish': '{"status":"registered"}',
      };
      pk = _Pk(created: _created, asserted: _asserted);
    });

    test('first passkey: grant header on begin and finish, bodies', () async {
      bodies['/v1/manage/first-passkey/begin'] = jsonEncode(beginBody(now));
      final b = await bridge();
      expect(b.firstPasskeyAvailable, isTrue);
      await b.firstPasskey();
      expect(calls.length, 2);
      expect(calls[0], startsWith('POST /v1/manage/first-passkey/begin'));
      expect(calls[1], startsWith('POST /v1/manage/first-passkey/finish'));
      expect(
        headersSeen.every((h) => h['X-OTPanda-Enrollment'] == tok('G')),
        isTrue,
      );
      final fin = jsonDecode(calls[1].split(' ').skip(2).join(' '));
      expect(fin['token'], tok('B'));
      expect(fin['response']['response']['attestationObject'], 'o');
    });

    test('finish sent: the grant is spent, even when the answer is a failure',
        () async {
      bodies['/v1/manage/first-passkey/begin'] = jsonEncode(beginBody(now));
      statuses['/v1/manage/first-passkey/finish'] = 503;
      final b = await bridge();
      expect(b.controller.session?.enrollGrant, isNotNull);
      await expectLater(b.firstPasskey(), throwsA(isA<ClientFailure>()));
      expect(b.controller.session?.enrollGrant, isNull);
      expect(b.firstPasskeyAvailable, isFalse);
      calls.clear();
      await expectLater(b.firstPasskey(), throwsStateError);
      expect(calls, isEmpty);
    });

    test('no grant: first passkey is not offered', () async {
      final b = await bridge(grant: false);
      expect(b.firstPasskeyAvailable, isFalse);
      await expectLater(b.firstPasskey(), throwsStateError);
      expect(calls, isEmpty);
    });

    test('cancel at the OS sheet never calls finish', () async {
      bodies['/v1/manage/first-passkey/begin'] = jsonEncode(beginBody(now));
      pk.created = null;
      final b = await bridge();
      await expectLater(b.firstPasskey(), throwsStateError);
      expect(calls.length, 1);
    });

    test('server refusal on finish is a failure, not success', () async {
      bodies['/v1/manage/first-passkey/begin'] = jsonEncode(beginBody(now));
      statuses['/v1/manage/first-passkey/finish'] = 409;
      final b = await bridge();
      await expectLater(b.firstPasskey(), throwsA(isA<ClientFailure>()));
    });

    test('add passkey: verify, then register with the new grant', () async {
      bodies['/v1/manage/passkey/add/verify-begin'] = jsonEncode({
        'token': tok('V'),
        'expiresAt': now + 100000,
        'options': {
          'rpId': 'otpanda.github.io',
          'userVerification': 'required',
          'challenge': _challenge,
          'allowCredentials': [],
        },
      });
      bodies['/v1/manage/passkey/add/verify-finish'] = jsonEncode({
        'token': tok('Z'),
        'expiresAt': now + 100000,
      });
      bodies['/v1/manage/passkey/add/register-begin'] = jsonEncode(
        beginBody(now),
      );
      final b = await bridge();
      await b.addPasskey();
      expect(calls.map((c) => c.split(' ')[1]), [
        '/v1/manage/passkey/add/verify-begin',
        '/v1/manage/passkey/add/verify-finish',
        '/v1/manage/passkey/add/register-begin',
        '/v1/manage/passkey/add/register-finish',
      ]);
      expect(headersSeen.length, 2);
      expect(
        headersSeen.every((h) => h['X-OTPanda-Enrollment'] == tok('Z')),
        isTrue,
      );
    });
  });
}

void signupTests() {
  group('native signup', () {
    late List<String> paths;
    late List<Map<String, dynamic>> bodies;
    late int beginStatus, finishStatus;
    late bool existing;
    late _St st;
    late _Pk pk;
    final now = DateTime.now().millisecondsSinceEpoch;

    NativeSessionController ctl() => NativeSessionController(
      NativeAuth(
        post: (p, b) async {
          paths.add(p);
          bodies.add(Map<String, dynamic>.from(b));
          if (p == '/auth/native/signup/email') {
            return (status: 202, body: {'status': 'accepted'});
          }
          if (p == '/auth/native/signup/begin') {
            if (beginStatus != 200) return (status: beginStatus, body: null);
            return existing
                ? (status: 200, body: {'existing': true})
                : (
                    status: 200,
                    body: {
                      'token': 'signup-token',
                      'options': beginBody(now)['options'],
                      'expires_at': now + 100000,
                    },
                  );
          }
          if (p == '/auth/native/signup/finish') {
            return finishStatus == 200
                ? (
                    status: 200,
                    body: {
                      'device_id': 'DEV',
                      'access': 'a',
                      'access_expires_at': 9999999999999,
                    },
                  )
                : (status: finishStatus, body: null);
          }
          return (status: 404, body: null);
        },
        keystore: _Ks(),
        browser: _Br(),
        google: _G(),
        store: st,
        apiOrigin: 'https://api.example',
        launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
      ),
    );

    setUp(() {
      paths = [];
      bodies = [];
      beginStatus = 200;
      finishStatus = 200;
      existing = false;
      st = _St();
      pk = _Pk(created: _created);
    });

    test('email, code, passkey: same renewal key, session stored', () async {
      final c = ctl();
      await c.signupEmail('a@b.co');
      expect(c.auth.signupStage, 'email-code');
      await c.signupBegin('a@b.co', 'ABCD2345');
      expect(c.auth.signupStage, 'signup-ready');
      await c.signupFinish(pk);
      expect(c.phase, NativeSessionPhase.signedIn);
      expect(st.id, 'DEV');
      expect(paths, [
        '/auth/native/signup/email',
        '/auth/native/signup/begin',
        '/auth/native/signup/finish',
      ]);
      final keys = bodies.map((b) => b['renewal_key']).toSet();
      expect(keys.length, 1);
      expect(bodies[1]['email_code'], 'ABCD2345');
      expect(bodies[2]['token'], 'signup-token');
      expect(c.auth.signupStage, isNull);
    });

    test('wrong code stays on the code step', () async {
      final c = ctl();
      await c.signupEmail('a@b.co');
      beginStatus = 401;
      await c.signupBegin('a@b.co', 'WRONG222');
      expect(c.auth.signupStage, 'code-invalid');
    });

    test('existing account ends signup with the sign-in message', () async {
      final c = ctl();
      await c.signupEmail('a@b.co');
      existing = true;
      await c.signupBegin('a@b.co', 'ABCD2345');
      expect(c.lastError, 'signup_existing');
      expect(c.auth.signupStage, isNull);
    });

    test(
      'cancel at the OS sheet keeps the ceremony and never finishes',
      () async {
        final c = ctl();
        await c.signupEmail('a@b.co');
        await c.signupBegin('a@b.co', 'ABCD2345');
        pk.created = null;
        await c.signupFinish(pk);
        expect(paths.contains('/auth/native/signup/finish'), isFalse);
        expect(c.auth.signupStage, 'signup-ready');
      },
    );

    test('finish failure never repeats creation and shows recovery', () async {
      final c = ctl();
      await c.signupEmail('a@b.co');
      await c.signupBegin('a@b.co', 'ABCD2345');
      finishStatus = 503;
      await c.signupFinish(pk);
      expect(c.lastError, 'signup_unconfirmed');
      expect(c.auth.signupStage, isNull);
      expect(c.phase, isNot(NativeSessionPhase.signedIn));
      expect(st.id, isNull);
      expect(paths.where((p) => p.endsWith('/finish')).length, 1);
    });

    test('abort releases sign-in so Google works again', () async {
      final c = ctl();
      await c.signupEmail('a@b.co');
      await c.signupAbort();
      expect(c.auth.signupStage, isNull);
      await c.signupEmail('a@b.co');
      expect(c.auth.signupStage, 'email-code');
    });
  });
}
