import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/native/native_app.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/google_link.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/recovery_contract.dart';
import 'package:otpanda_client/session_contract.dart';

class _Ks implements NativeKeystore {
  int deletes = 0;
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
  Future<void> deleteKey() async => deletes++;
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

const _asserted =
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","authenticatorData":"a","signature":"s","userHandle":null}}';

class _Pk implements PasskeyAssertionSource, PasskeyCreationSource {
  _Pk(this.out);
  String? out;
  int gets = 0;
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async {
    gets++;
    return out;
  }

  @override
  Future<String?> create(String requestJson) async => null;
}

String _tok(String c) => 'otpda_${c * 55}';

void main() {
  late List<(String, String, Map<String, dynamic>?)> calls;
  late bool unlinked; // synthetic server state: Google sessions revoked
  late int renewStatus;
  late _Ks ks;
  late _St store;
  late _Pk pk;

  NativeSessionController ctl() => NativeSessionController(
    NativeAuth(
      post: (p, b) async {
        if (p == '/auth/native/renew') {
          if (renewStatus != 200) return (status: renewStatus, body: null);
          return (
            status: 200,
            body: {'access': 'ACC', 'access_expires_at': 9999999999999},
          );
        }
        if (p == '/auth/native/challenge') {
          return (
            status: 200,
            body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
          );
        }
        return (status: 404, body: null);
      },
      keystore: ks,
      browser: _Br(),
      google: _G(),
      store: store,
      apiOrigin: 'https://api.example',
      launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
    ),
  );

  NativeSessionBridge make(NativeSessionController c, {required bool on}) =>
      NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async {
          final j = body == null
              ? null
              : jsonDecode(body) as Map<String, dynamic>;
          calls.add((m, p, j));
          if (unlinked) return const SessionResponse(401, '{}');
          if (p == '/v1/manage/recovery/begin') {
            return SessionResponse(
              200,
              jsonEncode({
                'token': _tok('T'),
                'expiresAt': DateTime.now().millisecondsSinceEpoch + 60000,
                'options': {
                  'rpId': 'otpanda.github.io',
                  'userVerification': 'required',
                  'challenge': 'A' * 43,
                  'allowCredentials': [
                    {'id': 'c1'},
                  ],
                },
              }),
            );
          }
          if (p == '/v1/manage/recovery/finish') {
            unlinked = true; // synthetic: the server revoked Google sessions
            return const SessionResponse(200, '{}');
          }
          return const SessionResponse(200, '{"records":[]}');
        },
        passkeys: pk,
        creation: pk,
        settingsEnabled: on,
      );

  setUp(() {
    calls = [];
    unlinked = false;
    renewStatus = 200;
    ks = _Ks();
    store = _St();
    pk = _Pk(_asserted);
  });

  test('settings off: Disconnect is not offered and nothing is sent', () async {
    final c = ctl();
    await c.start();
    final b = make(c, on: false);
    expect(b, isA<GoogleLinkBridge>());
    expect(b.googleDisconnectAvailable, isFalse);
    await expectLater(b.disconnectGoogle(), throwsUnsupportedError);
    expect(calls, isEmpty);
    expect(pk.gets, 0);
  });

  test('settings on: begin with kind google-unlink and no target, one passkey, finish with same body, token and response', () async {
    final c = ctl();
    await c.start();
    final b = make(c, on: true);
    expect(b.googleDisconnectAvailable, isTrue);
    await b.disconnectGoogle();
    expect(pk.gets, 1);
    final begin = calls.firstWhere((e) => e.$2 == '/v1/manage/recovery/begin');
    final fin = calls.firstWhere((e) => e.$2 == '/v1/manage/recovery/finish');
    expect(begin.$3, {'kind': 'google-unlink'});
    expect(fin.$3!['kind'], 'google-unlink');
    expect(fin.$3!.containsKey('target'), isFalse);
    expect(fin.$3!['token'], _tok('T'));
    expect((fin.$3!['response'] as Map)['id'], 'i');
  });

  test(
    'dismissed passkey prompt: refused, finish never sent, session untouched',
    () async {
      pk.out = null;
      final c = ctl();
      await c.start();
      final b = make(c, on: true);
      await expectLater(b.disconnectGoogle(), throwsA(isA<RecoveryRefused>()));
      expect(calls.any((e) => e.$2.endsWith('/finish')), isFalse);
      expect(c.phase, NativeSessionPhase.signedIn);
    },
  );

  test('success revokes the Google session: next call 401, renew refused, signInRequired with the key and id kept', () async {
    final c = ctl();
    await c.start();
    final b = make(c, on: true);
    await b.disconnectGoogle();
    renewStatus = 401; // synthetic: the unlinked session cannot renew
    final r = await b.read('/v1/manage/entries');
    expect(r.status, isNot(200));
    expect(c.phase, NativeSessionPhase.signInRequired);
    expect(ks.deletes, 0);
    expect(store.id, 'DEV');
  });
  testWidgets('revoked next-read replaces signed-in root with shared sign-in', (
    t,
  ) async {
    final c = ctl();
    final b = make(c, on: true);
    await t.pumpWidget(
      NativeApp(
        controller: c,
        googleAvailable: true,
        authBridge: b,
        signedInBuilder: (_) => Scaffold(
          body: FilledButton(
            onPressed: () async {
              await b.disconnectGoogle();
              renewStatus = 401;
              await b.read('/v1/manage/entries');
            },
            child: const Text('Synthetic unlink and refresh'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Synthetic unlink and refresh'));
    await t.pumpAndSettle();
    expect(find.text('Synthetic unlink and refresh'), findsNothing);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.textContaining('Remember'), findsNothing);
    expect(c.phase, NativeSessionPhase.signInRequired);
    expect(ks.deletes, 0);
    expect(t.takeException(), isNull);
  });
}
