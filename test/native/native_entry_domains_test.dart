import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
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

void main() {
  late List<(String, String, String?, String?)> calls;
  late SessionResponse Function(String m, String p) reply;

  Future<NativeSessionBridge> make() async {
    final c = NativeSessionController(
      NativeAuth(
        post: (p, b) async => p == '/auth/native/renew'
            ? (
                status: 200,
                body: {'access': 'ACC', 'access_expires_at': 9999999999999},
              )
            : p == '/auth/native/challenge'
            ? (
                status: 200,
                body: {'device_id': 'DEV', 'nonce': 'n', 'expires_at': 5},
              )
            : (status: 404, body: null),
        keystore: _Ks(),
        browser: _Br(),
        google: _G(),
        store: _St(),
        apiOrigin: 'https://api.example',
        launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
      ),
    );
    await c.start();
    return NativeSessionBridge(c, (m, p, {body, query, required bearer}) async {
      calls.add((m, p, body, bearer));
      return reply(m, p);
    });
  }

  setUp(() => calls = []);

  test(
    'read: GET with the bearer, parsed; odd shapes are not available',
    () async {
      reply = (m, p) => SessionResponse(
        200,
        '{"associations":[{"entryId":"a","domains":["x.com"]}]}',
      );
      final b = await make();
      expect(await b.readEntryDomains(), {
        'a': ['x.com'],
      });
      expect(calls.single.$1, 'GET');
      expect(calls.single.$2, '/v1/manage/entry/domains');
      expect(calls.single.$4, 'ACC');
      reply = (m, p) => const SessionResponse(
        200,
        '{"associations":[{"entryId":"a","domains":["*.x.com"]}]}',
      );
      await expectLater(b.readEntryDomains(), throwsStateError);
      reply = (m, p) => const SessionResponse(503, '{}');
      await expectLater(b.readEntryDomains(), throwsStateError);
    },
  );

  test('replace: one POST with exact keys, normalized list returned', () async {
    reply = (m, p) => const SessionResponse(200, '{"ok":true}');
    final b = await make();
    expect(await b.replaceEntryDomains('a', ['X.com', 'x.com', 'y.org']), [
      'x.com',
      'y.org',
    ]);
    expect(calls.single.$1, 'POST');
    expect(calls.single.$2, '/v1/manage/entry/domains');
    expect(jsonDecode(calls.single.$3!), {
      'entryId': 'a',
      'domains': ['x.com', 'y.org'],
    });
  });

  test('replace: invalid input sends nothing; unconfirmed answers throw and are not retried', () async {
    reply = (m, p) => const SessionResponse(500, '{"ok":true}');
    final b = await make();
    await expectLater(
      b.replaceEntryDomains('a', ['*.x.com']),
      throwsStateError,
    );
    await expectLater(
      b.replaceEntryDomains('a b', ['x.com']),
      throwsStateError,
    );
    expect(calls, isEmpty);
    await expectLater(b.replaceEntryDomains('a', ['x.com']), throwsStateError);
    expect(calls.length, 1);
    reply = (m, p) => const SessionResponse(200, '{}');
    await expectLater(b.replaceEntryDomains('a', ['x.com']), throwsStateError);
    expect(calls.length, 2);
  });
}
