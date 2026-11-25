import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_app.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_passkey.dart';

class _Ks implements NativeKeystore {
  int begun = 0, committed = 0, discarded = 0;
  @override
  Future<Uint8List> ensureKey() async =>
      Uint8List.fromList([4, ...List.filled(64, 1)]);
  @override
  Future<Uint8List> beginNewKey() async {
    begun++;
    return ensureKey();
  }

  @override
  Future<void> commitNewKey() async => committed++;
  @override
  Future<void> discardNewKey() async => discarded++;
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

class _Rec implements RecognitionStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> clear() async => value = null;
}

class _G implements GoogleIdTokenSource {
  @override
  bool get available => true;
  @override
  Future<String?> idToken({required String nonce}) async => 'IDTOK';
}

class _Br implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

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
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","authenticatorData":"a","signature":"s","userHandle":"u"}}';
String _tok(String c) => 'otpda_${c * 55}';

void main() {
  late int now;
  late _Ks ks;
  late _St st;
  late _Rec rec;
  late List<(String, Map<String, dynamic>)> sent;
  late Map<String, ({int status, Map<String, dynamic>? body})> replies;

  NativeAuth make() => NativeAuth(
    post: (p, b) async {
      sent.add((p, Map<String, dynamic>.from(b)));
      final r = replies[p];
      if (r == null) throw Exception('network');
      return r;
    },
    keystore: ks,
    browser: _Br(),
    google: _G(),
    store: st,
    apiOrigin: 'https://api.example',
    launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
    recognition: rec,
    now: () => now,
  );

  Map<String, dynamic> cont({String kind = 'link'}) => {
    'status': 'continue_required',
    'kind': kind,
    'continuation': _tok('K'),
    'email': 'a@b.co',
    'expires_at': now + 600000,
  };

  Map<String, dynamic> begin() => {
    'token': _tok('T'),
    'expires_at': now + 100000,
    'options': {
      'rpId': 'otpanda.github.io',
      'userVerification': 'required',
      'challenge': 'A' * 43,
      'allowCredentials': [
        {'type': 'public-key', 'id': 'cred1'},
      ],
    },
  };

  setUp(() {
    now = DateTime.now().millisecondsSinceEpoch;
    ks = _Ks();
    st = _St();
    rec = _Rec();
    sent = [];
    replies = {
      '/auth/native/google/begin': (
        status: 200,
        body: {'nonce': 'N', 'expires_at': 9},
      ),
      '/auth/native/google/complete': (status: 200, body: cont()),
      '/auth/native/google/continue/begin': (status: 200, body: begin()),
      '/auth/native/google/continue/finish': (
        status: 200,
        body: {
          'device_id': 'DEV',
          'access': 'a',
          'access_expires_at': 9999999999999,
          'recognition': 'REC',
        },
      ),
    };
  });

  Future<NativeAuth> pending({bool? remember = true}) async {
    final a = make();
    await expectLater(
      a.signInWithGoogle(remember: remember),
      throwsA(
        isA<NativeAuthException>().having(
          (e) => e.kind,
          'kind',
          'continue_required',
        ),
      ),
    );
    return a;
  }

  test('continue_required holds the pending key and creates nothing', () async {
    final a = await pending();
    expect(a.googleLinkStage, 'google-link');
    expect(a.googleLinkEmail, 'a@b.co');
    expect(ks.discarded, 0);
    expect(ks.committed, 0);
    expect(st.id, isNull);
    // one pending attempt: another sign-in is busy
    await expectLater(
      a.signInWithGoogle(),
      throwsA(isA<NativeAuthException>().having((e) => e.kind, 'k', 'busy')),
    );
  });

  test(
    'link: begin and finish carry the same renewal key; session issued',
    () async {
      final a = await pending();
      final pk = _Pk(_asserted);
      final s = await a.googleLinkFinish(pk);
      final renewal = sent
          .firstWhere((e) => e.$1.endsWith('google/complete'))
          .$2['renewal_key'];
      final b = sent.firstWhere((e) => e.$1.endsWith('continue/begin')).$2;
      final f = sent.firstWhere((e) => e.$1.endsWith('continue/finish')).$2;
      expect(b['continuation'], _tok('K'));
      expect(b['renewal_key'], renewal);
      expect(f['renewal_key'], renewal);
      expect(f['continuation'], _tok('K'));
      expect(f['token'], _tok('T'));
      expect((f['response'] as Map)['id'], 'i');
      expect(s.deviceId, 'DEV');
      expect(st.id, 'DEV');
      expect(ks.committed, 1);
      expect(rec.value, 'REC');
      expect(a.googleLinkStage, isNull);
      expect(pk.requests.single, contains('cred1'));
    },
  );

  test('dismissed prompt keeps the continuation; retry works', () async {
    final a = await pending();
    await expectLater(
      a.googleLinkFinish(_Pk(null)),
      throwsA(
        isA<NativeAuthException>().having((e) => e.kind, 'k', 'cancelled'),
      ),
    );
    expect(a.googleLinkStage, 'google-link');
    expect(sent.any((e) => e.$1.endsWith('continue/finish')), isFalse);
    await a.googleLinkFinish(_Pk(_asserted));
    expect(st.id, 'DEV');
  });

  test('cancel drops the continuation and discards the pending key', () async {
    final a = await pending();
    await a.googleLinkAbort();
    expect(a.googleLinkStage, isNull);
    expect(ks.discarded, 1);
    expect(st.id, isNull);
    replies['/auth/native/google/complete'] = (
      status: 200,
      body: {
        'device_id': 'D2',
        'access': 'a',
        'access_expires_at': 9999999999999,
      },
    );
    expect((await a.signInWithGoogle()).deviceId, 'D2');
  });

  test(
    'finish failure ends the attempt as unconfirmed, no retry call',
    () async {
      for (final r in <({int status, Map<String, dynamic>? body})?>[
        (status: 401, body: {'error': 'invalid_grant'}),
        (status: 503, body: null),
        null,
      ]) {
        final a = make();
        sent.clear();
        if (r == null) {
          replies.remove('/auth/native/google/continue/finish');
        } else {
          replies['/auth/native/google/continue/finish'] = r;
        }
        await expectLater(
          a.signInWithGoogle(),
          throwsA(isA<NativeAuthException>()),
        );
        await expectLater(
          a.googleLinkFinish(_Pk(_asserted)),
          throwsA(
            isA<NativeAuthException>().having(
              (e) => e.kind,
              'k',
              'google_link_unconfirmed',
            ),
          ),
        );
        expect(a.googleLinkStage, isNull);
        expect(st.id, isNull);
        expect(sent.where((e) => e.$1.endsWith('continue/finish')).length, 1);
      }
    },
  );

  test('begin 401 ends the attempt; no prompt, no finish', () async {
    final a = await pending();
    replies['/auth/native/google/continue/begin'] = (
      status: 401,
      body: {'error': 'invalid_grant'},
    );
    final pk = _Pk(_asserted);
    await expectLater(
      a.googleLinkFinish(pk),
      throwsA(isA<NativeAuthException>()),
    );
    expect(a.googleLinkStage, isNull);
    expect(pk.requests, isEmpty);
  });

  test('kind email or a malformed continuation is not accepted', () async {
    for (final body in [
      cont(kind: 'email'),
      {...cont(), 'continuation': 'short'},
      {...cont(), 'expires_at': now - 1},
      {...cont(), 'email': ''},
    ]) {
      replies['/auth/native/google/complete'] = (status: 200, body: body);
      final a = make();
      await expectLater(
        a.signInWithGoogle(),
        throwsA(
          isA<NativeAuthException>().having((e) => e.kind, 'k', 'protocol'),
        ),
      );
      expect(a.googleLinkStage, isNull);
      expect(ks.discarded, greaterThan(0));
    }
  });

  test('an expired held continuation is dropped before any request', () async {
    final a = await pending();
    now += 601000;
    sent.clear();
    await expectLater(
      a.googleLinkFinish(_Pk(_asserted)),
      throwsA(isA<NativeAuthException>()),
    );
    expect(sent, isEmpty);
    expect(a.googleLinkStage, isNull);
  });

  test('step-up request builder rejects other rp, long lists, bad ids', () {
    String run(Map<String, dynamic> b) =>
        passkeyStepUpRequestJson(b, nowMs: now);
    expect(
      run(begin()),
      contains('"allowCredentials":[{"type":"public-key","id":"cred1"}]'),
    );
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (b) => (b['options'] as Map)['rpId'] = 'evil.example',
      (b) => (b['options'] as Map)['userVerification'] = 'preferred',
      (b) => (b['options'] as Map)['allowCredentials'] = List.generate(
        21,
        (i) => {'id': 'x$i'},
      ),
      (b) => (b['options'] as Map)['allowCredentials'] = [
        {'id': 'bad id!'},
      ],
      (b) => (b['options'] as Map).remove('allowCredentials'),
      (b) => b['expires_at'] = now - 1,
    ]) {
      final b = begin();
      mutate(b);
      expect(() => run(b), throwsA(isA<PasskeyException>()));
    }
  });

  testWidgets(
    'shared screen: Google continue shows the link step, then signs in',
    (t) async {
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = NativeSessionController(make());
      final pk = _Pk(_asserted);
      final bridge = NativeSessionBridge(
        c,
        (m, p, {body, query, required bearer}) async =>
            const SessionResponse(401, '{}'),
        passkeys: pk,
        googleAvailable: true,
      );
      await t.pumpWidget(
        NativeApp(controller: c, googleAvailable: true, authBridge: bridge),
      );
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Google').first);
      await t.pumpAndSettle();
      expect(find.text('Connect your account.'), findsOneWidget);
      expect(find.textContaining('a@b.co'), findsNothing);
      expect(
        find.text('Verify existing account and connect Google'),
        findsOneWidget,
      );
      expect(find.text('Sign-in did not complete. Try again.'), findsNothing);
      await t.tap(find.text('Verify existing account and connect Google'));
      await t.pumpAndSettle();
      expect(pk.requests.length, 1);
      expect(c.phase, NativeSessionPhase.signedIn);
    },
  );
}
