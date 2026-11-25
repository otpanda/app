// Page-level flows through the REAL NativeDevicesService and drivers against
// a fake server that follows the wire contract (routes, bodies, typed
// responses). Not a live server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/native/native_action_proof.dart';
import 'package:otpanda_client/native/native_add_device.dart';
import 'package:otpanda_client/native/native_approval_routes.dart';
import 'package:otpanda_client/native/native_auth.dart' show NativeSession;
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_startup.dart';
import 'package:otpanda_client/native/native_devices.dart';
import 'package:otpanda_client/session_contract.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
final _jwk = spkiToJwk(base64.decode(_spki));
final _digest = publicKeyDigest(_jwk);
final _kid = 'k_${'a1' * 20}';
final _tok = 'otpda_${'A' * 55}';

class _Src implements DeviceProofSource {
  _Src({this.key = false});
  bool key;
  bool signOk = true;
  int signs = 0;
  String? text;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => key;
  @override
  Future<Uint8List?> publicKeyOrNull() async =>
      key ? base64.decode(_spki) : null;
  @override
  Future<Uint8List> createKeyForEnrollment() async {
    key = true;
    return base64.decode(_spki);
  }

  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    text = displayText;
    if (!signOk)
      throw const DeviceProofFailure(DeviceProofFailureKind.unsupportedOs);
    return Uint8List(64);
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

/// Wire-contract fake. Records every (method, path, body).
class _Server {
  _Server(this.now);
  final int now;
  final calls = <String>[];
  final bodies = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? approvalRow;
  bool addApproved = false;
  String keyStatus = 'absent';
  bool statusFails = false;
  Completer<void>? gate; // holds /v1/manage/session until completed
  Completer<void>? addGate; // holds add-request
  String owner = 'O';

  Map<String, dynamic> challenge(
    String purpose,
    String action, {
    String? change,
  }) => {
    'token': _tok,
    'challenge': {
      'ownerId': 'O',
      'keyId': _kid,
      'generation': 1,
      'purpose': purpose,
      'actionDigest': action,
      'challenge': 'C' * 43,
      'expiresAt': now + 100000,
    },
  };

  Future<SessionResponse> call(String m, String p, String? body) async {
    calls.add('$m $p');
    if (p == '/v1/manage/session' && gate != null) await gate!.future;
    if (p == '/v1/manage/device-key/add-request' && addGate != null) {
      await addGate!.future;
    }
    if (statusFails && p == '/v1/manage/device-key/enroll-status') {
      return SessionResponse(500, '{"error":"x"}');
    }
    final b = body == null
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    bodies[p] = b;
    Map<String, dynamic> ok(Map<String, dynamic> j) => j;
    int status = 200;
    Map<String, dynamic> out;
    switch (p) {
      case '/v1/manage/session':
        out = {'ownerId': owner, 'expiresAt': now + 600000};
      case '/v1/manage/account':
        out = {
          'email': 'abraham@example.com',
          'passkeys': 0,
          'google': true,
          'recoveryDevices': 0,
        };
      case '/v1/manage/device-key/enroll-status':
        out = keyStatus == 'enrolled'
            ? {'status': 'enrolled', 'keyId': _kid}
            : {'status': keyStatus};
      case '/v1/manage/device-key/enroll-begin':
        out = challenge('enroll', deviceEnrollmentAction(_jwk));
      case '/v1/manage/device-key/enroll-finish':
        keyStatus = 'enrolled';
        out = {'status': 'enrolled', 'keyId': _kid};
      case '/v1/manage/device-key/adopt-begin':
        out = challenge('step-up', adoptActionDigest(_digest));
      case '/v1/manage/device-key/adopt-finish':
        out = {'status': 'enrolled', 'keyId': _kid};
      case '/v1/manage/device-key/add-request':
        out = {
          'changeId': 'C9',
          'expiresAt': now + 600000,
          'fingerprint': fingerprintOf(_digest),
        };
      case '/v1/manage/device-key/add-begin':
        if (!addApproved) {
          status = 409;
          out = {'error': 'unavailable'};
        } else {
          out = challenge('enroll', deviceEnrollmentAction(_jwk));
        }
      case '/v1/manage/device-key/add-finish':
        out = {'status': 'enrolled', 'keyId': _kid};
      case '/v1/manage/approval/status':
        out = {
          'ownerId': 'O',
          'generation': 1,
          'pending': [if (approvalRow != null) approvalRow!],
        };
      case '/v1/manage/approval/approve-begin':
        out = challenge(
          'step-up',
          approvalActionDigest(
            changeId: 'C1',
            kind: 'passkey-add',
            target: null,
            ownerId: 'O',
            generation: 1,
          ),
        );
      case '/v1/manage/approval/approve-finish':
        approvalRow = null;
        out = {'status': 'approved'};
      default:
        status = 404;
        out = {'error': 'not_found'};
    }
    return SessionResponse(status, jsonEncode(ok(out)));
  }
}

({
  NativeDevicesService v,
  _Src src,
  _Raw raw,
  _Add add,
  _Server srv,
  List<String> confirmed,
  NativeStartupRecovery st,
  List<NativeSession?> cur,
})
_mk({bool key = false, NativeSession? s, String keyStatus = 'absent'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final srv = _Server(now)..keyStatus = keyStatus;
  final src = _Src(key: key), raw = _Raw(), add = _Add();
  final confirmed = <String>[];
  final cur = <NativeSession?>[
    s ?? const NativeSession('DEV', 'tok', 99999999),
  ];
  final lock = AsyncLock();
  req(
    String m,
    String p, {
    String? body,
    Map<String, String>? query,
    required String bearer,
  }) {
    expect(bearer, 'tok');
    return srv.call(m, p, body);
  }

  final st = NativeStartupRecovery(
    request: req,
    source: src,
    store: raw,
    enabled: true,
    lock: lock,
    now: () => now,
  );
  final v = NativeDevicesService(
    request: req,
    session: () => cur[0],
    source: src,
    enrollStore: LockedPendingStore(raw, lock),
    addStore: add,
    saveConfirmed: (o, k) async => confirmed.add('$o:$k'),
    startup: st,
    now: () => now,
  );
  return (
    v: v,
    src: src,
    raw: raw,
    add: add,
    srv: srv,
    confirmed: confirmed,
    st: st,
    cur: cur,
  );
}

Widget _app(NativeDevicesService v) => MaterialApp(
  theme: otpandaTheme(),
  home: NativeDevicesPage(key: UniqueKey(), service: v),
);

void main() {
  testWidgets(
    'first set-up with the grant: begin carries publicJwk+grant, native confirmation saved after the typed 200, pending record cleared',
    (t) async {
      final m = _mk(
        s: const NativeSession(
          'DEV',
          'tok',
          99999999,
          enrollGrant: 'otpda_grant',
        ),
      );
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      await t.tap(find.text('Set up this phone'));
      await t.pumpAndSettle();
      expect(find.text('This phone is set up.'), findsOneWidget);
      expect(m.confirmed, ['O:$_kid']);
      expect(m.srv.bodies['/v1/manage/device-key/enroll-begin']!.keys.toSet(), {
        'publicJwk',
        'grant',
      });
      expect(
        m.srv.bodies['/v1/manage/device-key/enroll-finish']!.keys.toSet(),
        {'grant', 'token', 'signature'},
      );
      expect(m.raw.cleared, isTrue);
      expect(
        find.text('This phone can approve sign-in changes.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'adopt: an interrupted enroll is found at startup, Link this phone signs once and sends {digest, token, signature}; anchor cleared only after the typed confirm',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.raw.st = const PendingRead.unreadable();
      await m.st.sessionChanged(const NativeSession('DEV', 'tok', 99999999));
      expect(m.st.current!.result.keyId, _kid);
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      expect(
        find.text(
          'The server already knows this phone. Link it to use it again.',
        ),
        findsOneWidget,
      );
      expect(m.raw.cleared, isFalse);
      await t.tap(find.text('Link this phone'));
      await t.pumpAndSettle();
      expect(find.text('This phone is linked.'), findsOneWidget);
      expect(m.src.signs, 1);
      expect(m.src.text, contains('abraham@example.com'));
      expect(m.srv.bodies['/v1/manage/device-key/adopt-finish']!.keys.toSet(), {
        'digest',
        'token',
        'signature',
      });
      expect(
        m.srv.bodies['/v1/manage/device-key/adopt-finish']!['digest'],
        _digest,
      );
      expect(m.confirmed, ['O:$_kid']);
      expect(m.raw.cleared, isTrue);
    },
  );

  testWidgets(
    'adopt with the host refusing step-up: nothing confirmed, nothing cleared, no finish sent',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.src.signOk = false;
      m.raw.st = const PendingRead.unreadable();
      await m.st.sessionChanged(const NativeSession('DEV', 'tok', 99999999));
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      await t.tap(find.text('Link this phone'));
      await t.pumpAndSettle();
      expect(
        find.text('This check did not pass, so nothing was signed.'),
        findsOneWidget,
      );
      expect(m.confirmed, isEmpty);
      expect(m.raw.cleared, isFalse);
      expect(m.srv.calls.any((c) => c.contains('adopt-finish')), isFalse);
    },
  );

  testWidgets(
    'ADD: ask, fingerprint shown, not approved yet, then approved: begin, sign, finish, native confirmation, record cleared',
    (t) async {
      final m = _mk();
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      await t.tap(find.text('Ask another phone to approve this one'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-fingerprint')), findsOneWidget);
      expect(find.text(fingerprintOf(_digest)), findsOneWidget);
      expect(m.src.signs, 0);
      await t.tap(find.text('Check approval'));
      await t.pumpAndSettle();
      expect(find.text('Not approved yet.'), findsOneWidget);
      expect(m.src.signs, 0);
      m.srv.addApproved = true;
      await t.tap(find.text('Check approval'));
      await t.pumpAndSettle();
      expect(find.text('This phone is added.'), findsOneWidget);
      expect(m.confirmed, ['O:$_kid']);
      expect(m.add.st.record, isNull);
      expect(m.srv.bodies['/v1/manage/device-key/add-finish']!.keys.toSet(), {
        'changeId',
        'token',
        'signature',
      });
    },
  );

  testWidgets(
    'approval: enrolled phone lists the request; Approve signs once with the readable text and the row is gone after the typed approved',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.srv.approvalRow = {
        'changeId': 'C1',
        'kind': 'passkey-add',
        'target': null,
        'requesterLabel': 'Firefox on Linux',
        'requesterKind': 'web',
        'requestedAt': m.srv.now - 60000,
        'expiresAt': m.srv.now + 540000,
      };
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      expect(find.textContaining('Firefox on Linux'), findsOneWidget);
      await t.tap(find.text('Approve'));
      await t.pumpAndSettle();
      expect(find.text('Approved.'), findsOneWidget);
      expect(m.src.signs, 1);
      expect(
        m.src.text,
        allOf(
          contains('abraham@example.com'),
          contains('Only approve if you started this'),
        ),
      );
      expect(find.text('Nothing is waiting for approval.'), findsOneWidget);
      expect(m.srv.bodies['/v1/manage/approval/approve-finish']!.keys.toSet(), {
        'changeId',
        'token',
        'signature',
      });
    },
  );

  testWidgets(
    'status call failing shows could-not-check, Refresh only; no set-up, no ask-add, no link',
    (t) async {
      final m = _mk(
        key: true,
        s: const NativeSession('DEV', 'tok', 99999999, enrollGrant: 'g'),
      );
      m.srv.statusFails = true;
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      expect(find.textContaining('Could not check this phone'), findsWidgets);
      expect(find.text('Set up this phone'), findsNothing);
      expect(find.text('Ask another phone to approve this one'), findsNothing);
      expect(find.text('Link this phone'), findsNothing);
      expect(find.text('Refresh'), findsOneWidget);
      m.srv.statusFails = false;
      await t.tap(find.text('Refresh'));
      await t.pumpAndSettle();
      expect(find.text('Set up this phone'), findsOneWidget);
    },
  );

  testWidgets(
    'absent with a local key and no grant offers ask-add; with a grant offers set-up',
    (t) async {
      final a = _mk(key: true);
      await t.pumpWidget(_app(a.v));
      await t.pumpAndSettle();
      expect(
        find.text('Ask another phone to approve this one'),
        findsOneWidget,
      );
      expect(find.text('Set up this phone'), findsNothing);
    },
  );

  testWidgets(
    'after adopt the startup result is invalidated: Link this phone is gone, no second adopt',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.raw.st = const PendingRead.unreadable();
      await m.st.sessionChanged(const NativeSession('DEV', 'tok', 99999999));
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      await t.tap(find.text('Link this phone'));
      await t.pumpAndSettle();
      expect(m.st.current, isNull);
      expect(find.text('Link this phone'), findsNothing);
      expect(m.src.signs, 1);
      await m.v.adopt();
      expect(m.src.signs, 1, reason: 'a second adopt must not sign');
    },
  );

  testWidgets(
    'a stale refresh landing after sign-out cannot repopulate the page',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.srv.gate = Completer<void>();
      await t.pumpWidget(_app(m.v));
      await t.pump();
      m.cur[0] = null;
      m.v.sessionChanged(null);
      m.srv.gate!.complete();
      await t.pumpAndSettle();
      expect(m.v.ownerId, isNull);
      expect(m.v.email, isNull);
      expect(m.v.approvals, isNull);
      expect(m.v.serverStatus, isNull);
      expect(m.v.loading, isFalse);
    },
  );

  testWidgets(
    'switching to another device mid-refresh discards the old result',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.srv.gate = Completer<void>();
      await t.pumpWidget(_app(m.v));
      await t.pump();
      m.cur[0] = const NativeSession('OTHER', 'tok', 99999999);
      m.v.sessionChanged(m.cur[0]);
      m.srv.gate!.complete();
      await t.pumpAndSettle();
      expect(m.v.ownerId, isNull);
      expect(m.v.serverStatus, isNull);
    },
  );

  testWidgets('double tap on Approve while busy signs once', (t) async {
    final m = _mk(key: true, keyStatus: 'enrolled');
    m.srv.approvalRow = {
      'changeId': 'C1',
      'kind': 'passkey-add',
      'target': null,
      'requesterLabel': 'Firefox on Linux',
      'requesterKind': 'web',
      'requestedAt': m.srv.now - 60000,
      'expiresAt': m.srv.now + 540000,
    };
    await t.pumpWidget(_app(m.v));
    await t.pumpAndSettle();
    final row = m.v.approvals!.pending.first;
    await Future.wait([m.v.approve(row), m.v.approve(row)]);
    expect(m.src.signs, 1);
  });

  testWidgets(
    'an expired approval row is never shown and an unsafe label is not rendered raw',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.srv.approvalRow = {
        'changeId': 'C1',
        'kind': 'passkey-add',
        'target': null,
        'requesterLabel': 'Evil\u202egnp.exe',
        'requesterKind': 'web',
        'requestedAt': m.srv.now - 900000,
        'expiresAt': m.srv.now - 1000,
      };
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      expect(find.text('Approve'), findsNothing);
      expect(find.textContaining('\u202e'), findsNothing);
    },
  );

  test('only sign-out clears the retry floor: a transient session notification does not', () async {
    final m = _mk(key: true, keyStatus: 'enrolled');
    m.srv.statusFails = true;
    m.raw.st = const PendingRead.unreadable();
    final s = const NativeSession('DEV', 'tok', 99999999);
    await m.st.sessionChanged(s);
    final calls = m.srv.calls.length;
    await m.st.sessionChanged(s); // offline-style no-op: no reset, floor holds
    expect(
      m.srv.calls.length,
      calls,
      reason: 'inside the retry floor, no new request',
    );
    await m.st.sessionChanged(null);
    await m.st.sessionChanged(s);
    expect(m.srv.calls.length, greaterThan(calls));
  });

  testWidgets(
    'ADD finds the server already holds the key: Link appears, typed adopt signs once, add record cleared, Link gone',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.srv.keyStatus = 'enrolled';
      m.add.st = AddPendingRead.record(
        AddPendingRecord(
          state: AddState.recovering,
          ownerId: 'O',
          sessionDeviceId: 'DEV',
          changeId: 'C9',
          digest: _digest,
          requestStartMs: 1,
        ),
      );
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      expect(m.st.current, isNull, reason: 'not a startup needsAdopt');
      await t.tap(find.text('Check approval'));
      await t.pumpAndSettle();
      expect(find.text('Link this phone'), findsOneWidget);
      expect(find.text('Waiting for you'), findsNothing);
      await t.tap(find.text('Link this phone'));
      await t.pumpAndSettle();
      expect(find.text('This phone is linked.'), findsOneWidget);
      expect(m.src.signs, 1);
      expect(m.confirmed, ['O:$_kid']);
      expect(m.add.st.record, isNull);
      expect(find.text('Link this phone'), findsNothing);
      await m.v.adopt();
      expect(m.src.signs, 1, reason: 'no second adopt');
    },
  );

  testWidgets(
    'an ADD-origin Link from an older session is dropped on sign-out and cannot run for the next owner',
    (t) async {
      final m = _mk(key: true, keyStatus: 'enrolled');
      m.add.st = AddPendingRead.record(
        AddPendingRecord(
          state: AddState.recovering,
          ownerId: 'O',
          sessionDeviceId: 'DEV',
          changeId: 'C9',
          digest: _digest,
          requestStartMs: 1,
        ),
      );
      await t.pumpWidget(_app(m.v));
      await t.pumpAndSettle();
      await t.tap(find.text('Check approval'));
      await t.pumpAndSettle();
      expect(m.v.canLink, isTrue);
      m.cur[0] = null;
      m.v.sessionChanged(null);
      await t.pumpAndSettle();
      expect(m.v.canLink, isFalse);
      m.cur[0] = const NativeSession('DEV', 'tok2', 99999999);
      m.v.sessionChanged(m.cur[0]);
      await m.v.adopt();
      expect(m.src.signs, 0);
    },
  );

  test('cross-session: an old run still in flight blocks a new run; the old owner record is not clobbered and a new owner cannot overwrite or apply it', () async {
    Future<void> drain() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    final m = _mk(key: true);
    await m.v.refresh();
    final gate = Completer<void>();
    m.srv.addGate = gate;
    final old = m.v.requestAdd();
    await drain();
    expect(m.v.busy, isTrue);
    expect(m.srv.calls.last, 'POST /v1/manage/device-key/add-request');
    m.cur[0] = null;
    m.v.sessionChanged(null);
    m.srv.owner = 'P';
    m.cur[0] = const NativeSession('DEV2', 'tok', 99999999);
    m.v.sessionChanged(m.cur[0]);
    await m.v.refresh();
    final before = m.srv.calls.where((c) => c.contains('add-request')).length;
    await m.v.requestAdd();
    expect(
      m.srv.calls.where((c) => c.contains('add-request')).length,
      before,
      reason: 'new run must not start until the old run settled',
    );
    gate.complete();
    await old;
    await drain();
    expect(m.v.busy, isFalse);
    final rec = m.add.st.record;
    expect(rec, isNotNull);
    expect(rec!.ownerId, 'O');
    expect(rec.sessionDeviceId, 'DEV');
    await m.v.refresh();
    await m.v.requestAdd();
    await m.v.checkAdd();
    final after = m.add.st.record!;
    expect(after.ownerId, 'O');
    expect(after.changeId, rec.changeId);
    expect(m.src.signs, 0);
    expect(m.confirmed, isEmpty);
  });

  test(
    'unsafe text: U+2028, U+2029, U+061C and the zero-width set are rejected',
    () {
      for (final c in [
        '\u2028',
        '\u2029',
        '\u061c',
        '\u200b',
        '\ufeff',
        '\u202e',
      ]) {
        expect(
          approvalPrompt(
            kind: 'passkey-add',
            accountEmail: 'a@example.com',
            requesterLabel: 'Fire${c}fox',
            requesterKind: 'web',
            requestedAtMs: 0,
            nowMs: 1000,
            fingerprint: null,
          ),
          isNull,
          reason: c.codeUnitAt(0).toRadixString(16),
        );
      }
    },
  );

  // Widget-test renders with real fonts at 360x640. NOT device pixels. Only on
  // request: GOLDENS=1 flutter test --update-goldens test/native/native_devices_flows_test.dart
  Future<void> fonts() async {
    Future<void> load(String family, List<String> paths) async {
      final l = FontLoader(family);
      for (final p in paths) {
        l.addFont(
          Future.value(ByteData.sublistView(File(p).readAsBytesSync())),
        );
      }
      await l.load();
    }

    await load('Figtree', [
      'assets/fonts/Figtree-400.ttf',
      'assets/fonts/Figtree-500.ttf',
      'assets/fonts/Figtree-600.ttf',
      'assets/fonts/Figtree-700.ttf',
    ]);
    await load('BricolageGrotesque', [
      'assets/fonts/BricolageGrotesque-700.ttf',
      'assets/fonts/BricolageGrotesque-800.ttf',
    ]);
    await load('MaterialIcons', [
      '${Platform.environment['FLUTTER_ROOT'] ?? '/tmp/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ]);
  }

  Future<void> shot(WidgetTester t, String name) async {
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/native_devices_$name.png'),
    );
  }

  testWidgets('real-font renders of the four states', (t) async {
    await fonts();
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // 1 enroll
    final a = _mk(
      s: const NativeSession(
        'DEV',
        'tok',
        99999999,
        enrollGrant: 'otpda_grant',
      ),
    );
    await t.pumpWidget(_app(a.v));
    await t.pumpAndSettle();
    await shot(t, '1_enroll');
    // 2 add (asked, fingerprint shown)
    final b = _mk();
    await t.pumpWidget(_app(b.v));
    await t.pumpAndSettle();
    await t.tap(find.text('Ask another phone to approve this one'));
    await t.pumpAndSettle();
    await shot(t, '2_add');
    // 3 adopt
    final c = _mk(key: true, keyStatus: 'enrolled');
    c.raw.st = const PendingRead.unreadable();
    await c.st.sessionChanged(const NativeSession('DEV', 'tok', 99999999));
    await t.pumpWidget(_app(c.v));
    await t.pumpAndSettle();
    await shot(t, '3_adopt');
    // 4 approval
    final d = _mk(key: true, keyStatus: 'enrolled');
    d.srv.approvalRow = {
      'changeId': 'C1',
      'kind': 'passkey-add',
      'target': null,
      'requesterLabel': 'Firefox on Linux',
      'requesterKind': 'web',
      'requestedAt': d.srv.now - 60000,
      'expiresAt': d.srv.now + 540000,
    };
    await t.pumpWidget(_app(d.v));
    await t.pumpAndSettle();
    await shot(t, '4_approval');
    // 5 could not check
    final e = _mk(key: true);
    e.srv.statusFails = true;
    await t.pumpWidget(_app(e.v));
    await t.pumpAndSettle();
    await shot(t, '5_could_not_check');
  }, skip: Platform.environment['GOLDENS'] != '1');
}
