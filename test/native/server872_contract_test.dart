// REAL-SERVER contract test. The bridge (/tmp/s872/test/dart-bridge.mjs) runs
// the composed 872 server code (approvals-http, device-key-http, the real
// services, SQLite migrations, real ECDSA verification) and this Dart client
// logic talks to it over loopback HTTP. Skipped unless SERVER872=1.
// Not covered: the real worker ingress, D1, the native allowlist matcher,
// /v1/manage/session and /v1/manage/account (bridge answers those with a
// minimal stub), real Android Keystore, camera, passkeys, Google.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_add_device.dart';
import 'package:otpanda_client/native/native_approval_routes.dart';
import 'package:otpanda_client/native/native_auth.dart' show NativeSession;
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_startup.dart';
import 'package:otpanda_client/native/native_devices.dart';
import 'package:otpanda_client/native/native_enroll_recovery.dart';
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
  final HttpClientRequest r;
  try {
    r = await hc.openUrl(m, Uri.parse('http://127.0.0.1:$port$p'));
  } catch (e) {
    print('OPENERR $e');
    rethrow;
  }
  r.headers.set('authorization', 'Bearer $bearer');
  // exactly application/json, as the native client sends it
  r.headers.set('content-type', 'application/json');
  if (body != null) r.add(utf8.encode(body));
  final resp = await r.close();
  final out = await resp.transform(utf8.decoder).join();
  if (Platform.environment['TRACE'] == '1') {
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
  Future<Uint8List> createKeyForEnrollment() async {
    key = true;
    return _spki;
  }

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

class _Raw implements PendingEnrollStore {
  PendingRead st = const PendingRead.none();
  bool cleared = false;
  @override
  Future<PendingRead> read() async => st;
  @override
  Future<void> write(PendingRecord r) async => st = PendingRead.record(r);
  @override
  Future<void> clear() async {
    cleared = true;
    st = const PendingRead.none();
  }
}

class _Add implements AddPendingStore {
  AddPendingRead st = const AddPendingRead.none();
  @override
  Future<AddPendingRead> read() async => st;
  @override
  Future<void> write(AddPendingRecord r) async => st = AddPendingRead.record(r);
  @override
  Future<void> clear() async => st = const AddPendingRead.none();
}

({
  NativeDevicesService v,
  _Real src,
  _Raw raw,
  _Add add,
  NativeStartupRecovery st,
  List<String> confirmed,
})
phone(String sess, String who, {bool key = false}) {
  final s = state['sessions'][sess] as Map<String, dynamic>;
  final now = state['now'] as int;
  final src = _Real(who, key: key), raw = _Raw(), add = _Add();
  final confirmed = <String>[];
  final lock = AsyncLock();
  final st = NativeStartupRecovery(
    request: req,
    source: src,
    store: raw,
    enabled: true,
    lock: lock,
    now: () => now,
  );
  final ns = NativeSession(
    s['deviceId'] as String,
    s['access'] as String,
    9999999999999,
  );
  final v = NativeDevicesService(
    request: req,
    session: () => ns,
    source: src,
    enrollStore: LockedPendingStore(raw, lock),
    addStore: add,
    saveConfirmed: (o, k) async => confirmed.add('$o:$k'),
    startup: st,
    now: () => now,
  );
  return (v: v, src: src, raw: raw, add: add, st: st, confirmed: confirmed);
}

({
  NativeDevicesService v,
  _Real src,
  _Raw raw,
  _Add add,
  NativeStartupRecovery st,
  List<String> confirmed,
})
googleOnly(String name, String who) {
  final e = state['extra'][name] as Map<String, dynamic>;
  final now = state['now'] as int;
  final src = _Real(who), raw = _Raw(), add = _Add();
  final confirmed = <String>[];
  final lock = AsyncLock();
  final st = NativeStartupRecovery(
    request: req,
    source: src,
    store: raw,
    enabled: true,
    lock: lock,
    now: () => now,
  );
  final ns = NativeSession(
    e['deviceId'] as String,
    e['access'] as String,
    9999999999999,
    enrollGrant: e['grant'] as String?,
  );
  final v = NativeDevicesService(
    request: req,
    session: () => ns,
    source: src,
    enrollStore: LockedPendingStore(raw, lock),
    addStore: add,
    saveConfirmed: (o, k) async => confirmed.add('$o:$k'),
    startup: st,
    now: () => now,
  );
  return (v: v, src: src, raw: raw, add: add, st: st, confirmed: confirmed);
}

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

  test(
    'server 872: approve (web passkey-add) by an enrolled phone, then add a second phone, then adopt on a third session',
    () async {
      await bridge('/_t/reset-limits', {});
      final owner = state['owner'] as String;
      // 1. Phone A (key A is enrolled server-side): status, list, approve.
      final a = phone('A', 'A', key: true);
      await a.v.refresh();
      expect(a.v.checkFailed, isFalse, reason: a.v.message);
      expect(a.v.serverStatus, ServerKeyStatus.enrolled);
      expect(a.v.ownKeyId, 'key-a');
      final web = await bridge('/_t/web-request', {});
      expect(web['changeId'], isNotNull);
      await a.v.refresh();
      expect(a.v.approvals!.pending, hasLength(1));
      final row = a.v.approvals!.pending.first;
      expect(row.requesterKind, 'web');
      await a.v.approve(row);
      expect(a.v.message, 'Approved.');
      expect(a.src.signs, 1);
      var db = await bridge('/_t/db');
      expect(
        (db['approvals'] as List).where((r) => r['approved_at'] != null),
        hasLength(1),
      );
      expect(a.src.text, contains('approve@example.test'));

      // 2. Phone B (new key B, session B) asks; phone A approves; B finishes.
      final b = phone('B', 'B');
      await b.v.refresh();
      expect(b.v.notEnrolled, isTrue, reason: b.v.message);
      await b.v.requestAdd();
      expect(
        b.v.addFingerprint,
        fingerprintOf(state['B']['digest'] as String),
        reason: b.v.message,
      );
      await a.v.refresh();
      final addRow = a.v.approvals!.pending.firstWhere(
        (r) => r.kind == 'device-key-add',
      );
      expect(addRow.target, state['B']['digest']);
      await a.v.approve(addRow);
      expect(a.v.message, 'Approved.');
      await b.v.checkAdd();
      expect(
        b.v.message,
        'This phone is added.',
        reason: 'server said: ${b.v.message}',
      );
      db = await bridge('/_t/db');
      final bk = (db['keys'] as List).firstWhere(
        (k) => k['public_key_digest'] == state['B']['digest'],
      );
      expect(b.confirmed, ['$owner:${bk['key_id']}']);
      expect(b.add.st.record, isNull);

      // 3. A third session on the same phone key B: server already holds it,
      // the local enroll slot is unreadable -> needsAdopt -> Link -> typed adopt.
      final c = phone('C', 'B', key: true);
      c.raw.st = const PendingRead.unreadable();
      await c.st.sessionChanged(
        NativeSession(
          state['sessions']['C']['deviceId'] as String,
          state['sessions']['C']['access'] as String,
          9999999999999,
        ),
      );
      expect(
        c.st.current?.result.outcome,
        RecoveryOutcome.needsAdopt,
        reason: '${c.st.current?.result.outcome}',
      );
      await c.v.refresh();
      expect(c.v.canLink, isTrue);
      await c.v.adopt();
      expect(c.v.message, 'This phone is linked.');
      expect(c.confirmed, ['$owner:${bk['key_id']}']);
      expect(c.raw.cleared, isTrue);
      expect(c.v.canLink, isFalse);
    },
    skip: Platform.environment['SERVER872'] == '1'
        ? false
        : 'needs SERVER872=1 and /tmp/s872',
  );

  test(
    'server 872 (neutral status/adopt delta): a passkey-method android session reads status, lists and approves a request, and adopts its own key; real signatures',
    () async {
      await bridge('/_t/reset-limits', {});
      final p = phone('P', 'A', key: true);
      await p.v.refresh();
      expect(p.v.checkFailed, isFalse, reason: p.v.message);
      expect(p.v.serverStatus, ServerKeyStatus.enrolled);
      expect(p.v.ownKeyId, 'key-a');
      // approve a fresh web request from the passkey-method phone
      await bridge('/_t/new-web-request', {});
      await p.v.refresh();
      expect(p.v.approvals!.pending, isNotEmpty);
      await p.v.approve(p.v.approvals!.pending.first);
      expect(p.v.message, 'Approved.');
      // adopt: unreadable local slot -> needsAdopt -> typed adopt
      final q = phone('P', 'A', key: true);
      q.raw.st = const PendingRead.unreadable();
      final s = state['sessions']['P'] as Map<String, dynamic>;
      await q.st.sessionChanged(
        NativeSession(
          s['deviceId'] as String,
          s['access'] as String,
          9999999999999,
        ),
      );
      expect(q.st.current?.result.outcome, RecoveryOutcome.needsAdopt);
      await q.v.refresh();
      await q.v.adopt();
      expect(q.v.message, 'This phone is linked.');
      expect(q.confirmed, hasLength(1));
      expect(q.raw.cleared, isTrue);
    },
    skip: Platform.environment['SERVER872'] == '1'
        ? false
        : 'needs SERVER872=1 and /tmp/s872',
  );

  test(
    'server 872: first Google-only enrollment with the memory-only grant: begin (publicJwk+grant), real signature, finish, native confirmation saved, pending cleared; status then reads enrolled',
    () async {
      await bridge('/_t/reset-limits', {});
      final g = googleOnly('g1', 'K');
      expect(state['extra']['g1']['grant'], isNotNull);
      await g.v.refresh();
      expect(g.v.notEnrolled, isTrue, reason: g.v.message);
      expect(g.v.hasGrant, isTrue);
      await g.v.enroll();
      expect(g.v.message, 'This phone is set up.');
      expect(g.src.signs, 1);
      expect(g.confirmed, hasLength(1));
      expect(
        g.confirmed.single,
        startsWith('${state['extra']['g1']['owner']}:'),
      );
      expect(g.raw.st.record, isNull);
      expect(g.v.serverStatus, ServerKeyStatus.enrolled);
      final db = await bridge('/_t/db');
      expect(
        (db['keys'] as List).where(
          (k) => k['public_key_digest'] == state['K']['digest'],
        ),
        hasLength(1),
      );
      // the grant is single use: a second enroll attempt must not create anything
      final before = ((await bridge('/_t/db'))['keys'] as List).length;
      await g.v.enroll();
      expect((await bridge('/_t/db'))['keys'] as List, hasLength(before));
      expect(g.src.signs, 1, reason: 'a spent grant must not sign again');
    },
    skip: Platform.environment['SERVER872'] == '1'
        ? false
        : 'needs SERVER872=1 and /tmp/s872',
  );

  test(
    'server 872: first enrollment when the account already has a sign-in method: real 409 method_exists is shown as the existing-method message, nothing saved, no key',
    () async {
      await bridge('/_t/reset-limits', {});
      final g = googleOnly('g2', 'K2');
      await g.v.refresh();
      await g.v.enroll();
      expect(
        g.v.message,
        contains('already has a sign-in method'),
        reason: g.v.message,
      );
      expect(g.confirmed, isEmpty);
      expect(g.src.signs, 0);
    },
    skip: Platform.environment['SERVER872'] == '1'
        ? false
        : 'needs SERVER872=1 and /tmp/s872',
  );
}
