// ignore_for_file: library_private_types_in_public_api
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_action_proof.dart';
import 'package:otpanda_client/native/native_add_device.dart';
import 'package:otpanda_client/native/native_approval_routes.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_routes.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
final _jwk = spkiToJwk(base64.decode(_spki));
final _digest = publicKeyDigest(_jwk);
final _tok = 'otpda_${'A' * 55}';
typedef _R = ({int status, Map<String, dynamic>? body});

class _Src implements DeviceProofSource {
  int signs = 0, creates = 0;
  DeviceProofFailure? signFail;
  String? lastText;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => true;
  @override
  Future<Uint8List?> publicKeyOrNull() async => base64.decode(_spki);
  @override
  Future<Uint8List> createKeyForEnrollment() async {
    creates++;
    return base64.decode(_spki);
  }

  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    lastText = displayText;
    if (signFail != null) throw signFail!;
    return Uint8List.fromList(List.filled(64, 9));
  }
}

class _Store implements AddPendingStore {
  AddPendingRead st = const AddPendingRead.none();
  bool cleared = false, failWrite = false;
  @override
  Future<AddPendingRead> read() async => st;
  @override
  Future<void> write(AddPendingRecord r) async {
    if (failWrite) throw Exception('disk');
    st = AddPendingRead.record(r);
  }

  @override
  Future<void> clear() async {
    cleared = true;
    st = const AddPendingRead.none();
  }
}

Map<String, dynamic> _challenge({
  String? digest,
  String purpose = 'enroll',
  String owner = 'O',
  String key = 'K',
  int gen = 1,
  int exp = 100000,
}) => {
  'token': _tok,
  'challenge': {
    'ownerId': owner,
    'keyId': key,
    'generation': gen,
    'purpose': purpose,
    'actionDigest': digest ?? deviceEnrollmentAction(_jwk),
    'challenge': 'C' * 43,
    'expiresAt': exp,
  },
};

AddDeviceDriver _drv(
  _Src s,
  _Store st,
  Map<String, _R Function()> routes, {
  int now = 1000,
  List<String>? confirmed,
  List<String>? log,
  int? gen = 1,
}) => AddDeviceDriver(
  source: s,
  routes: AddDeviceRoutes((p, b) async {
    log?.add(p);
    final f = routes[p];
    if (f == null) throw Exception('lost');
    return f();
  }),
  store: st,
  ownerId: 'O',
  sessionDeviceId: 'D',
  expectedGeneration: gen,
  onEnrolled: (k) async => confirmed?.add(k),
  now: () => now,
);

const _req = '/v1/manage/device-key/add-request';
const _beg = '/v1/manage/device-key/add-begin';
const _fin = '/v1/manage/device-key/add-finish';

AddPendingRecord _requested({int aexp = 300000}) => AddPendingRecord(
  state: AddState.requested,
  ownerId: 'O',
  sessionDeviceId: 'D',
  changeId: 'C1',
  digest: _digest,
  requestStartMs: 500,
  approvalExpiresAtMs: aexp,
);

late _Store lastStore;

void main() {
  test('request: key made without a prompt, approval expiry capped at now+600 s, record persisted before use', () async {
    final s = _Src(), st = _Store();
    final d = _drv(s, st, {
      _req: () => (
        status: 200,
        body: {
          'changeId': 'C1',
          'expiresAt': 1000 + 600000,
          'fingerprint': fingerprintOf(_digest),
        },
      ),
    });
    final r = await d.request();
    expect(r.outcome, AddOutcome.requested);
    expect(r.fingerprint, fingerprintOf(_digest));
    expect(s.signs, 0);
    expect(st.st.record!.state, AddState.requested);
    final long = _drv(_Src(), _Store(), {
      _req: () => (
        status: 200,
        body: {
          'changeId': 'C1',
          'expiresAt': 1000 + 600001,
          'fingerprint': fingerprintOf(_digest),
        },
      ),
    });
    expect((await long.request()).outcome, AddOutcome.refused);
    final lost = _drv(_Src(), _Store(), {});
    expect((await lost.request()).outcome, AddOutcome.unknown);
  });

  test('null add-begin keeps the record and never wipes it, until the approval window is long gone', () async {
    final st = _Store()..st = AddPendingRead.record(_requested());
    final s = _Src();
    final d = _drv(s, st, {
      _beg: () => (status: 409, body: {'error': 'unavailable'}),
    });
    expect(
      (await d.checkApprovalAndFinish()).outcome,
      AddOutcome.notApprovedYet,
    );
    expect(st.cleared, isFalse);
    expect(s.signs, 0);
    final lost = _drv(s, st, {});
    expect((await lost.checkApprovalAndFinish()).outcome, AddOutcome.unknown);
    expect(st.cleared, isFalse);
    final late = _drv(s, st, {
      _beg: () => (status: 409, body: null),
    }, now: 300000 + 30001);
    expect(
      (await late.checkApprovalAndFinish()).outcome,
      AddOutcome.approvalExpired,
    );
    expect(st.cleared, isTrue);
  });

  test(
    'add-begin challenge is validated against OWN key before any prompt',
    () async {
      final cases = <Map<String, dynamic>>[
        _challenge(digest: 'a' * 64),
        _challenge(owner: 'EVIL'),
        _challenge(gen: 2),
        _challenge(exp: 1000),
        _challenge(exp: 1000 + 150001),
        _challenge(purpose: 'step-up'),
      ];
      for (final c in cases) {
        final s = _Src(),
            st = _Store()..st = AddPendingRead.record(_requested());
        final r = await _drv(s, st, {
          _beg: () => (status: 200, body: c),
        }).checkApprovalAndFinish();
        expect(r.outcome, anyOf(AddOutcome.refused, AddOutcome.notApprovedYet));
        expect(s.signs, 0);
        expect(st.cleared, isFalse);
      }
    },
  );

  test('happy path persists begun then finishSent (token+signature) before the finish, then confirms natively and clears', () async {
    final s = _Src(), st = _Store()..st = AddPendingRead.record(_requested());
    final confirmed = <String>[];
    var seen = false;
    final d = _drv(s, st, {
      _beg: () => (status: 200, body: _challenge()),
      _fin: () {
        final r = st.st.record!;
        seen =
            r.state == AddState.finishSent &&
            r.token == _tok &&
            r.signature!.length == 64 &&
            r.keyId == 'K';
        return (status: 200, body: {'status': 'enrolled', 'keyId': 'K'});
      },
    }, confirmed: confirmed);
    final r = await d.checkApprovalAndFinish();
    expect(r.outcome, AddOutcome.enrolled);
    expect(seen, isTrue);
    expect(confirmed, ['K']);
    expect(st.cleared, isTrue);
    expect(s.signs, 1);
  });

  test('lost add-finish keeps the identical bytes; retry resends them with no new prompt, only inside 10 min', () async {
    final s = _Src(), st = _Store()..st = AddPendingRead.record(_requested());
    final bodies = <String>[];
    var lose = true;
    _R fin() {
      if (lose) throw Exception('lost');
      return (status: 200, body: {'status': 'enrolled', 'keyId': 'K'});
    }

    Future<_R> post(String p, Map<String, dynamic> b) async {
      if (p == _beg) return (status: 200, body: _challenge());
      bodies.add(jsonEncode(b));
      return fin();
    }

    AddDeviceDriver make(int now) => AddDeviceDriver(
      source: s,
      routes: AddDeviceRoutes(post),
      store: st,
      ownerId: 'O',
      sessionDeviceId: 'D',
      expectedGeneration: 1,
      onEnrolled: (_) async {},
      now: () => now,
    );
    final first = await make(1000).checkApprovalAndFinish();
    expect(first.outcome, AddOutcome.unknown);
    expect(st.st.record!.state, AddState.finishSent);
    lose = false;
    final again = await make(1000 + 599999).retryFinish();
    expect(again.outcome, AddOutcome.enrolled);
    expect(bodies[0], bodies[1]);
    expect(s.signs, 1);
    // Past the window nothing is sent.
    final st2 = _Store();
    st2.st = AddPendingRead.record(
      AddPendingRecord(
        state: AddState.finishSent,
        ownerId: 'O',
        sessionDeviceId: 'D',
        changeId: 'C1',
        digest: _digest,
        keyId: 'K',
        requestStartMs: 5,
        challengeExpiresAtMs: 50,
        sentAtMs: 1000,
        token: _tok,
        signature: Uint8List(64),
      ),
    );
    final n = bodies.length;
    final old = AddDeviceDriver(
      source: s,
      routes: AddDeviceRoutes(post),
      store: st2,
      ownerId: 'O',
      sessionDeviceId: 'D',
      onEnrolled: (_) async {},
      now: () => 1000 + 600000,
    );
    expect((await old.retryFinish()).outcome, AddOutcome.unknown);
    expect(bodies.length, n);
    expect(st2.cleared, isFalse);
  });

  test(
    'foreign owner or other session record is never applied or deleted',
    () async {
      final st = _Store()
        ..st = AddPendingRead.record(
          AddPendingRecord(
            state: AddState.requested,
            ownerId: 'OTHER',
            sessionDeviceId: 'D',
            changeId: 'C1',
            digest: _digest,
            requestStartMs: 1,
            approvalExpiresAtMs: 9,
          ),
        );
      final log = <String>[];
      final r = await _drv(_Src(), st, {}, log: log).checkApprovalAndFinish();
      expect(r.outcome, AddOutcome.refused);
      expect(log, isEmpty);
      expect(st.cleared, isFalse);
    },
  );

  // ---- approver driver ----
  ApprovalStatus status(int exp) => parseApprovalStatus({
    'ownerId': 'O',
    'generation': 3,
    'pending': [
      {
        'changeId': 'C1',
        'kind': 'passkey-add',
        'target': null,
        'requesterLabel': null,
        'requesterKind': 'web',
        'requestedAt': exp - 600000 < 1 ? 1 : exp - 600000,
        'expiresAt': exp,
      },
    ],
  })!;

  ApprovalDriver appr(
    _Src s,
    Future<_R> Function(String, Map<String, dynamic>) post,
  ) => ApprovalDriver(
    source: s,
    routes: ApprovalRoutes(post),
    ownerId: 'O',
    ownKeyId: 'K',
    accountEmail: 'me@x.io',
    now: () => 1000,
  );

  Map<String, dynamic> aChallenge(ApprovalRow r) => {
    'token': _tok,
    'challenge': {
      'ownerId': 'O',
      'keyId': 'K',
      'generation': 3,
      'purpose': 'step-up',
      'actionDigest': approvalActionDigest(
        changeId: r.changeId,
        kind: r.kind,
        target: r.target,
        ownerId: 'O',
        generation: 3,
      ),
      'challenge': 'C' * 43,
      'expiresAt': 50000,
    },
  };

  test('approve: readable text goes to the prompt; lost finish re-reads status and never re-signs; vanished row is not success', () async {
    final st = status(300000);
    final row = st.pending.single;
    final s = _Src();
    var statusCalls = 0;
    Future<_R> post(String p, Map<String, dynamic> b) async {
      if (p.endsWith('approve-begin')) {
        return (status: 200, body: aChallenge(row));
      }
      if (p.endsWith('approve-finish')) throw Exception('lost');
      statusCalls++;
      return (
        status: 200,
        body: {
          'ownerId': 'O',
          'generation': 3,
          'pending': [
            {
              'changeId': 'C1',
              'kind': 'passkey-add',
              'target': null,
              'requesterLabel': null,
              'requesterKind': 'web',
              'requestedAt': 1,
              'expiresAt': 300000,
            },
          ],
        },
      );
    }

    final d = appr(s, post);
    expect(await d.approve(st, row), ApproveOutcome.notConfirmed);
    expect(s.lastText, contains('me@x.io'));
    expect(s.signs, 1);
    expect(await d.approve(st, row), ApproveOutcome.notConfirmed);
    expect(s.signs, 1, reason: 'the same challenge is never signed twice');
    expect(statusCalls, 1);
    // Row gone after a lost finish: approved OR expired, never success.
    final gone = appr(_Src(), (p, b) async {
      if (p.endsWith('approve-begin')) {
        return (status: 200, body: aChallenge(row));
      }
      if (p.endsWith('approve-finish')) throw Exception('lost');
      return (
        status: 200,
        body: {'ownerId': 'O', 'generation': 3, 'pending': []},
      );
    });
    expect(await gone.approve(st, row), ApproveOutcome.approvedOrExpired);
    // Typed approved.
    final ok = appr(
      _Src(),
      (p, b) async => p.endsWith('approve-begin')
          ? (status: 200, body: aChallenge(row))
          : (status: 200, body: {'status': 'approved'}),
    );
    expect(await ok.approve(st, row), ApproveOutcome.approved);
  });

  test('approve: a bad challenge or a row beyond now+600 s never prompts; cancel is cancelled', () async {
    final st = status(300000);
    final row = st.pending.single;
    final bad = _Src();
    Map<String, dynamic> ch = aChallenge(row);
    (ch['challenge'] as Map)['actionDigest'] = 'a' * 64;
    expect(
      await appr(bad, (p, b) async => (status: 200, body: ch)).approve(st, row),
      ApproveOutcome.refused,
    );
    expect(bad.signs, 0);
    final far = status(1000 + 600001);
    final s2 = _Src();
    expect(
      await appr(
        s2,
        (p, b) async => (status: 200, body: aChallenge(far.pending.single)),
      ).approve(far, far.pending.single),
      ApproveOutcome.refused,
    );
    expect(s2.signs, 0);
    final c = _Src()
      ..signFail = const DeviceProofFailure(DeviceProofFailureKind.cancelled);
    expect(
      await appr(
        c,
        (p, b) async => (status: 200, body: aChallenge(row)),
      ).approve(st, row),
      ApproveOutcome.cancelled,
    );
  });

  test('begun record accepts a NEW validated keyId (server may assign one per begin)', () async {
    final s = _Src(), st = _Store();
    st.st = AddPendingRead.record(
      AddPendingRecord(
        state: AddState.begun,
        ownerId: 'O',
        sessionDeviceId: 'D',
        changeId: 'C1',
        digest: _digest,
        keyId: 'OLD',
        requestStartMs: 5,
        approvalExpiresAtMs: 300000,
        challengeExpiresAtMs: 50,
      ),
    );
    final r = await _drv(s, st, {
      _beg: () => (status: 200, body: _challenge(key: 'NEW')),
      _fin: () => (status: 200, body: {'status': 'enrolled', 'keyId': 'NEW'}),
    }).checkApprovalAndFinish();
    expect(r.outcome, AddOutcome.enrolled);
    expect(r.keyId, 'NEW');
  });

  test(
    'request reads the slot first and never overwrites a live record',
    () async {
      for (final rec in [
        AddPendingRecord(
          state: AddState.begun,
          ownerId: 'O',
          sessionDeviceId: 'D',
          changeId: 'C1',
          digest: _digest,
          keyId: 'K',
          requestStartMs: 5,
          approvalExpiresAtMs: 300000,
          challengeExpiresAtMs: 50,
        ),
        AddPendingRecord(
          state: AddState.finishSent,
          ownerId: 'O',
          sessionDeviceId: 'D',
          changeId: 'C1',
          digest: _digest,
          keyId: 'K',
          requestStartMs: 5,
          challengeExpiresAtMs: 50,
          sentAtMs: 900,
          token: _tok,
          signature: Uint8List(64),
        ),
      ]) {
        final s = _Src(), st = _Store()..st = AddPendingRead.record(rec);
        final log = <String>[];
        final r = await _drv(s, st, {}, log: log).request();
        expect(r.outcome, AddOutcome.inProgress);
        expect(log, isEmpty);
        expect(s.creates, 0);
        expect(st.st.record!.state, rec.state);
      }
      final unread = _Store()..st = const AddPendingRead.unreadable();
      final s = _Src();
      expect(
        (await _drv(s, unread, {}).request()).outcome,
        AddOutcome.inProgress,
      );
      expect(s.creates, 0);
      // live requested: returned as is, no new request
      final st = _Store()..st = AddPendingRead.record(_requested());
      final log = <String>[];
      final r = await _drv(_Src(), st, {}, log: log).request();
      expect(r.outcome, AddOutcome.requested);
      expect(log, isEmpty);
      // expired requested: replaced
      final old = _Store()..st = AddPendingRead.record(_requested(aexp: 900));
      final r2 = await _drv(_Src(), old, {
        _req: () => (
          status: 200,
          body: {
            'changeId': 'C2',
            'expiresAt': 1000 + 5000,
            'fingerprint': fingerprintOf(_digest),
          },
        ),
      }).request();
      expect(r2.outcome, AddOutcome.requested);
      expect(old.st.record!.changeId, 'C2');
    },
  );

  AddPendingRecord sent() => AddPendingRecord(
    state: AddState.finishSent,
    ownerId: 'O',
    sessionDeviceId: 'D',
    changeId: 'C1',
    digest: _digest,
    keyId: 'K',
    requestStartMs: 5,
    challengeExpiresAtMs: 50,
    sentAtMs: 1000,
    token: _tok,
    signature: Uint8List(64),
  );

  test('expired finishSent reconciles through enroll-status; never resends, never deletes a key', () async {
    Future<AddResult> run(
      Map<String, dynamic>? body,
      int status, {
      bool noRoutes = false,
      int now = 1000 + 600000 + 1,
    }) async {
      final st = _Store()..st = AddPendingRead.record(sent());
      final posted = <String>[];
      final d = AddDeviceDriver(
        source: _Src(),
        routes: AddDeviceRoutes((p, b) async {
          posted.add(p);
          return (status: 200, body: null);
        }),
        store: st,
        ownerId: 'O',
        sessionDeviceId: 'D',
        onEnrolled: (_) async {},
        statusRoutes: noRoutes
            ? null
            : DeviceStatusRoutes((p, b) async {
                posted.add(p);
                if (body == null) throw Exception('x');
                return (status: status, body: body);
              }),
        now: () => now,
      );
      final r = await d.retryFinish();
      expect(posted.where((p) => p.contains('add-finish')), isEmpty);
      expect(
        posted.every((p) => !p.contains('delete') && !p.contains('revoke')),
        isTrue,
      );
      lastStore = st;
      return r;
    }

    expect(
      (await run({'status': 'enrolled', 'keyId': 'K'}, 200)).outcome,
      AddOutcome.needsAdopt,
    );
    expect(lastStore.cleared, isFalse);
    expect(
      (await run({'status': 'revoked'}, 200)).outcome,
      AddOutcome.revokedNeedsMethod,
    );
    expect(lastStore.cleared, isFalse);
    expect((await run(null, 200)).outcome, AddOutcome.unknown);
    expect((await run({'status': 'absent'}, 500)).outcome, AddOutcome.unknown);
    expect(
      (await run({'status': 'absent'}, 200, noRoutes: true)).outcome,
      AddOutcome.unknown,
    );
    expect(lastStore.cleared, isFalse);
    // absent, but before the floor: wait. After: record cleared.
    final c = _Store()..st = AddPendingRead.record(sent());
    expect(c.st.record, isNotNull);
    expect(
      (await run({'status': 'absent'}, 200, now: 1000 + 600001)).outcome,
      AddOutcome.absentCleared,
    );
    expect(lastStore.cleared, isTrue);
  });

  test('approval prompt rejects control and bidi, caps the text, keeps the fingerprint', () {
    final fp = 'abcd-ef01-2345-6789';
    String? p(String email, String? label, {String kind = 'device-key-add'}) =>
        approvalPrompt(
          kind: kind,
          accountEmail: email,
          requesterLabel: label,
          requesterKind: kind == 'device-key-add' ? 'android' : 'web',
          requestedAtMs: 1000,
          nowMs: 1000 + 180000,
          fingerprint: fp,
        );
    expect(p('me@x.io', 'Pixel'), contains(fp));
    expect(p('me@x.io', 'Pi\nxel'), isNull);
    expect(p('me@x.io', 'Pi\u202Exel'), isNull);
    expect(p('me\u2066@x.io', 'Pixel'), isNull);
    expect(p('me@x.io\r', null), isNull);
    expect(p('me@x.io', 'a' * 65), isNull);
    final long = p('${'e' * 400}@x.io', 'b' * 64)!;
    expect(long.length, lessThanOrEqualTo(300));
    expect(long, contains(fp));
    expect(
      p('${'e' * 400}@x.io', null, kind: 'passkey-add')!.length,
      lessThanOrEqualTo(300),
    );
  });

  test('adopt-finish body is exactly {digest, token, signature}; old shape refused; k_+40hex keyIds parse', () async {
    Map<String, dynamic>? sent;
    final r = DeviceStatusRoutes((p, b) async {
      sent = b;
      return (
        status: 200,
        body: {'status': 'enrolled', 'keyId': 'k_${'a1' * 20}'},
      );
    });
    final id = await r.adoptFinish('d' * 64, _tok, Uint8List(64));
    expect(id, 'k_${'a1' * 20}');
    expect(sent!.keys.toSet(), {'digest', 'token', 'signature'});
    expect(sent!['digest'], 'd' * 64);
    expect(
      deviceKeyRequestAllowed('/v1/manage/device-key/adopt-finish', {
        'token': 't',
        'signature': 's',
      }),
      isFalse,
    );
    expect(
      deviceKeyRequestAllowed('/v1/manage/device-key/adopt-finish', {
        'digest': 'd',
        'token': 't',
        'signature': 's',
      }),
      isTrue,
    );
    final c = parseDeviceChallenge(_challenge(key: 'k_${'0f' * 20}'), 'enroll');
    expect(c, isNotNull);
    expect(c!.keyId, 'k_${'0f' * 20}');
  });

  test('unreadable slot: persisted start first, status reconcile, floor never resets, clear only after it', () async {
    final st = _Store()..st = const AddPendingRead.unreadable();
    final s = _Src();
    var body = <String, dynamic>{'status': 'absent'};
    final posted = <String>[];
    AddDeviceDriver mk(int now) => AddDeviceDriver(
      source: s,
      routes: AddDeviceRoutes((p, b) async {
        posted.add(p);
        return (status: 200, body: null);
      }),
      store: st,
      ownerId: 'O',
      sessionDeviceId: 'D',
      onEnrolled: (_) async {},
      statusRoutes: DeviceStatusRoutes((p, b) async {
        posted.add(p);
        return (status: 200, body: body);
      }),
      now: () => now,
    );
    // Run 1: write the anchor before the status call; absent before floor waits.
    var anchorSeenBeforeStatus = false;
    final d1 = AddDeviceDriver(
      source: s,
      routes: AddDeviceRoutes((p, b) async => (status: 200, body: null)),
      store: st,
      ownerId: 'O',
      sessionDeviceId: 'D',
      onEnrolled: (_) async {},
      statusRoutes: DeviceStatusRoutes((p, b) async {
        anchorSeenBeforeStatus = st.st.record?.state == AddState.recovering;
        return (status: 200, body: body);
      }),
      now: () => 10000,
    );
    expect((await d1.checkApprovalAndFinish()).outcome, AddOutcome.waiting);
    expect(anchorSeenBeforeStatus, isTrue);
    expect(st.st.record!.requestStartMs, 10000);
    // Run 2 starts later but before the floor: the start is NOT reset.
    expect(
      (await mk(10000 + 119000).checkApprovalAndFinish()).outcome,
      AddOutcome.waiting,
    );
    expect(st.st.record!.requestStartMs, 10000);
    expect(st.cleared, isFalse);
    // Run 2 after the floor: cleared.
    expect(
      (await mk(10000 + 120001).checkApprovalAndFinish()).outcome,
      AddOutcome.absentCleared,
    );
    expect(st.cleared, isTrue);
    expect(s.creates, 0);
    expect(
      posted.any((p) => p.contains('add-finish') || p.contains('add-request')),
      isFalse,
    );
    // enrolled and revoked keep the record.
    for (final c in [
      ({'status': 'enrolled', 'keyId': 'K'}, AddOutcome.needsAdopt),
      ({'status': 'revoked'}, AddOutcome.revokedNeedsMethod),
    ]) {
      final st2 = _Store()..st = const AddPendingRead.unreadable();
      body = c.$1;
      final d = AddDeviceDriver(
        source: s,
        routes: AddDeviceRoutes((p, b) async => (status: 200, body: null)),
        store: st2,
        ownerId: 'O',
        sessionDeviceId: 'D',
        onEnrolled: (_) async {},
        statusRoutes: DeviceStatusRoutes(
          (p, b) async => (status: 200, body: body),
        ),
        now: () => 5,
      );
      expect((await d.checkApprovalAndFinish()).outcome, c.$2);
      expect(st2.cleared, isFalse);
    }
    // No local key or failed anchor write: unknown, nothing written/cleared.
    final st3 = _Store()
      ..st = const AddPendingRead.unreadable()
      ..failWrite = true;
    final d3 = AddDeviceDriver(
      source: s,
      routes: AddDeviceRoutes((p, b) async => (status: 200, body: null)),
      store: st3,
      ownerId: 'O',
      sessionDeviceId: 'D',
      onEnrolled: (_) async {},
      statusRoutes: DeviceStatusRoutes(
        (p, b) async => (status: 200, body: body),
      ),
      now: () => 5,
    );
    expect((await d3.checkApprovalAndFinish()).outcome, AddOutcome.unknown);
    expect(st3.cleared, isFalse);
  });

  test('empty requesterLabel is treated as none in the prompt', () {
    final t = approvalPrompt(
      kind: 'passkey-add',
      accountEmail: 'me@x.io',
      requesterLabel: '',
      requesterKind: 'web',
      requestedAtMs: 1000,
      nowMs: 1000,
      fingerprint: null,
    );
    expect(t, contains('from a browser.'));
  });

  testWidgets(
    'a failing native pendingRead (oversize) is unreadable for both slots, never none',
    (t) async {
      const ch = MethodChannel('app.otpanda/device-proof');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
        throw PlatformException(code: 'failed');
      });
      addTearDown(
        () =>
            t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null),
      );
      expect((await ChannelAddPendingStore().read()).unreadable, isTrue);
      expect((await ChannelPendingStore().read()).unreadable, isTrue);
    },
  );

  test('prompt shows requester kind and request age, keeps the 16-hex fingerprint; bad kind or future date refuses', () {
    String? p({
      String kind = 'passkey-add',
      String rk = 'web',
      int at = 1000,
      int now = 1000 + 180000,
      String? label,
    }) => approvalPrompt(
      kind: kind,
      accountEmail: 'me@x.io',
      requesterLabel: label,
      requesterKind: rk,
      requestedAtMs: at,
      nowMs: now,
      fingerprint: 'abcd-ef01-2345-6789',
    );
    expect(
      p(),
      allOf(
        contains('a browser'),
        contains('3 minutes ago'),
        contains('Only approve if you started this'),
      ),
    );
    expect(
      p(rk: 'android', label: 'Pixel'),
      contains('an Android phone (Pixel)'),
    );
    expect(p(now: 1000 + 30000), contains('just now'));
    expect(
      p(kind: 'device-key-add', rk: 'android'),
      allOf(contains('abcd-ef01-2345-6789'), contains('holding it')),
    );
    expect(p(rk: 'ios'), isNull);
    expect(p(at: 1000 + 120000, now: 1000), isNull);
  });

  test('status rows: exactly the 7 keys, kind web|android, requestedAt sane; old 5-key shape and extras refused', () {
    Map<String, dynamic> row([void Function(Map<String, dynamic>)? f]) {
      final m = <String, dynamic>{
        'changeId': 'C1',
        'kind': 'passkey-add',
        'target': null,
        'requesterLabel': null,
        'requesterKind': 'web',
        'requestedAt': 1000,
        'expiresAt': 1000 + 600000,
      };
      f?.call(m);
      return m;
    }

    ApprovalStatus? parse(Map<String, dynamic> r) => parseApprovalStatus({
      'ownerId': 'O',
      'generation': 1,
      'pending': [r],
    });
    final ok = parse(row())!.pending.single;
    expect(ok.requesterKind, 'web');
    expect(ok.requestedAt, 1000);
    expect(
      parse(
        row((m) {
          m.remove('requesterKind');
          m.remove('requestedAt');
        }),
      ),
      isNull,
    );
    expect(parse(row((m) => m['lastSeen'] = 5)), isNull);
    expect(parse(row((m) => m['requesterKind'] = 'ios')), isNull);
    expect(parse(row((m) => m['requestedAt'] = '1000')), isNull);
    expect(parse(row((m) => m['requestedAt'] = 0)), isNull);
    expect(
      parse(row((m) => m['requestedAt'] = 999)),
      isNull,
      reason: 'window over 600 s',
    );
    expect(
      parse(row((m) => m['requestedAt'] = 700000)),
      isNull,
      reason: 'after expiry',
    );
    expect(
      parse(
        row((m) {
          m['kind'] = 'device-key-add';
          m['target'] = 'a' * 64;
        }),
      ),
      isNull,
      reason: 'a phone add comes from an android session',
    );
    expect(
      parse(
        row((m) {
          m['kind'] = 'device-key-add';
          m['target'] = 'a' * 64;
          m['requesterKind'] = 'android';
        }),
      ),
      isNotNull,
    );
  });
}
