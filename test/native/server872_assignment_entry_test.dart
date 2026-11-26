// ignore_for_file: library_private_types_in_public_api
// REAL-SERVER contract test for native assignment and entry edit. Same bridge
// as server872_contract_test.dart (real assignment-intent-http, assignment
// intents, entry-manage-http with native=true, SQLite migrations, ECDSA
// verification, device-key proofs). Skipped unless SERVER872=1.
// Not covered: the real worker ingress/allowlist, D1, Keystore, OS prompt.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_assignment.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_bridge.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';

late Process proc;
late int port;
late Map<String, dynamic> state;
final hc = HttpClient();

Future<Map<String, dynamic>> bridge(String path, [Object? body]) async {
  final r = await hc.openUrl(
    body == null ? 'GET' : 'POST',
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  r.headers.set('content-type', 'application/json');
  if (body != null) r.add(utf8.encode(jsonEncode(body)));
  final resp = await r.close();
  return jsonDecode(await resp.transform(utf8.decoder).join())
      as Map<String, dynamic>;
}

Future<SessionResponse> req(
  String m,
  String p, {
  String? body,
  Map<String, String>? query,
  required String bearer,
}) async {
  final r = await hc.openUrl(m, Uri.parse('http://127.0.0.1:$port$p'));
  r.headers.set('authorization', 'Bearer $bearer');
  r.headers.set('content-type', 'application/json');
  if (body != null) r.add(utf8.encode(body));
  final resp = await r.close();
  final out = await resp.transform(utf8.decoder).join();
  if (Platform.environment['TRACE'] == '1') {
    // ignore: avoid_print
    print('$m $p -> ${resp.statusCode} $out');
  }
  return SessionResponse(resp.statusCode, out);
}

class _Real implements DeviceProofSource {
  _Real(this.who, {this.key = false});
  final String who;
  bool key;
  int signs = 0;
  String? text;
  Uint8List get _spki => base64.decode(state[who]['spki'] as String);
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => key;
  @override
  Future<Uint8List?> publicKeyOrNull() async => key ? _spki : null;
  @override
  Future<Uint8List> createKeyForEnrollment() async => _spki;
  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    text = displayText;
    final r = await bridge('/_t/sign', {
      'who': who,
      'message': base64.encode(f.message),
    });
    expect(r['len'], 64);
    return base64.decode(r['signature'] as String);
  }
}

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
  _St(this.id);
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
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

/// A controller signed in with the REAL access token of a server session.
Future<NativeSessionController> controllerFor(String sess) async {
  final s = state['sessions'][sess] as Map<String, dynamic>;
  final c = NativeSessionController(
    NativeAuth(
      post: (p, b) async {
        if (p == '/auth/native/challenge') {
          return (
            status: 200,
            body: {'device_id': s['deviceId'], 'nonce': 'n', 'expires_at': 5},
          );
        }
        if (p == '/auth/native/renew') {
          return (
            status: 200,
            body: {'access': s['access'], 'access_expires_at': 9999999999999},
          );
        }
        return (status: 404, body: null);
      },
      keystore: _Ks(),
      browser: _Br(),
      google: _G(),
      store: _St(s['deviceId'] as String),
      apiOrigin: 'https://api.example',
      launchUrl: (c, s) => Uri.parse('https://x/#$c$s'),
    ),
  );
  await c.start();
  return c;
}

NativeSessionBridge bridgeFor(NativeSessionController c) =>
    NativeSessionBridge(c, req);

/// The same wiring native_root_io uses, over the real session bridge.
NativeAssignmentDriver driverFor(
  NativeSessionBridge b,
  NativeSessionController c,
  _Real src,
) => NativeAssignmentDriver(
  post: b.assignmentPost,
  source: src,
  identity: assignmentIdentity(
    readSession: () async {
      final r = await b.read('/v1/manage/session');
      return r.status == 200
          ? jsonDecode(r.body) as Map<String, dynamic>
          : null;
    },
    deviceId: () => c.session?.deviceId,
    source: src,
    post: b.deviceKeyPost,
  ),
  now: () => state['now'] as int,
  delay: (_) async {},
);

Future<Map<String, dynamic>> seed(String entry) async {
  await bridge('/_t/reset-limits', {});
  return bridge('/_t/seed-code', {'entry': entry});
}

String target(Map<String, dynamic> s) => jsonEncode({
  'sourceId': s['sourceId'],
  'eventId': s['eventId'],
  'entryId': s['entryId'],
});

Future<Object?> assigned(Map<String, dynamic> s) async =>
    (await bridge('/_t/incoming', {'eventId': s['eventId']}))['entry_id'];

void main() {
  final on = Platform.environment['SERVER872'] == '1';
  setUpAll(() async {
    if (!on) return;
    proc = await Process.start('node', [
      '--no-warnings',
      '${Platform.environment['SERVER872_DIR'] ?? '/tmp/s872'}/test/dart-bridge.mjs',
    ]);
    final line = await proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.startsWith('PORT='));
    port = int.parse(line.substring(5));
    state = await bridge('/_t/state');
  });
  tearDownAll(() async {
    if (!on) return;
    await bridge('/_t/stop', {});
  });
  final skip = on ? false : 'needs SERVER872=1';

  test('assignment: owner-private target, no proof, committed once', () async {
    final s = await seed('priv');
    final c = await controllerFor('A');
    final src = _Real('A', key: true);
    final d = driverFor(bridgeFor(c), c, src);
    final sum = jsonDecode(await d.prepare(target(s))) as Map;
    expect(sum['proofRequired'], false);
    expect(sum['activeRecipients'], 0);
    expect(await assigned(s), isNull, reason: 'prepare writes nothing');
    expect(await d.confirm(), 'assigned');
    expect(src.signs, 0);
    expect(await assigned(s), s['entryId']);
  }, skip: skip);

  test('assignment: shared target, real device-key signature, prompt text', () async {
    final s = await seed('shared');
    final c = await controllerFor('A');
    final src = _Real('A', key: true);
    final d = driverFor(bridgeFor(c), c, src);
    final sum = jsonDecode(await d.prepare(target(s))) as Map;
    expect(sum['proofRequired'], true);
    expect(sum['activeRecipients'], 1);
    expect(src.signs, 0);
    expect(await assigned(s), isNull);
    expect(await d.confirm(), 'assigned');
    expect(src.signs, 1);
    expect(src.text, contains('Shared'));
    expect(src.text, contains('1 person'));
    expect(await assigned(s), s['entryId']);
    // Status after the fact is typed 'assigned' (what a reconcile would read).
    final b = bridgeFor(c);
    expect(await d.reconcile(), 'assigned', reason: 'no longer pending');
    expect(b, isNotNull);
  }, skip: skip);

  test(
    'assignment: shared target on a phone without an enrolled key is refused',
    () async {
      final s = await seed('shared');
      final c = await controllerFor('B');
      final src = _Real('B', key: false);
      final d = driverFor(bridgeFor(c), c, src);
      await expectLater(d.prepare(target(s)), throwsA(anything));
      expect(d.state, 'unavailable');
      expect(src.signs, 0);
      expect(await assigned(s), isNull);
    },
    skip: skip,
  );

  test('entry edit: rename and account on the real native route', () async {
    await bridge('/_t/reset-limits', {});
    final s = await bridge('/_t/seed-code', {'entry': 'priv'});
    final id = s['entryId'] as String;
    final c = await controllerFor('A');
    final b = bridgeFor(c);
    await b.renameEntry(id, '  Renamed Entry ');
    var row = await bridge('/_t/entry', {'entryId': id});
    expect(row['label'], 'Renamed Entry');
    await b.updateAccount(id, ' me@x.io ');
    row = await bridge('/_t/entry', {'entryId': id});
    expect(row['account_name'], 'me@x.io');
    await b.updateAccount(id, null);
    row = await bridge('/_t/entry', {'entryId': id});
    expect(row['account_name'], isNull);
    // Same value again is still confirmed (server answers ok:true).
    await b.renameEntry(id, 'Renamed Entry');
    // Another owner's or a missing entry is "not confirmed", nothing changes.
    await expectLater(b.renameEntry('missing-entry', 'x'), throwsStateError);
  }, skip: skip);
}
