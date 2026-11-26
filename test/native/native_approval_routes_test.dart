import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_action_proof.dart';
import 'package:otpanda_client/native/native_approval_routes.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_routes.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
final _jwk = spkiToJwk(base64.decode(_spki));
final _digest = publicKeyDigest(_jwk);
final _tok = 'otpda_${'A' * 55}';
typedef _R = ({int status, Map<String, dynamic>? body});

Map<String, dynamic> _row({
  String kind = 'passkey-add',
  Object? target,
  Object? label = 'Firefox on Linux',
}) => {
  'changeId': 'C1',
  'kind': kind,
  'target': kind == 'device-key-add' ? (target ?? _digest) : null,
  'requesterLabel': label,
  'requesterKind': kind == 'device-key-add' ? 'android' : 'web',
  'requestedAt': 1,
  'expiresAt': 500000,
};

Map<String, dynamic> _status(List<Map<String, dynamic>> rows) => {
  'ownerId': 'O',
  'generation': 3,
  'pending': rows,
};

EnrollChallenge _ch(
  ApprovalRow r, {
  String? digest,
  int exp = 60000,
  String key = 'K',
  String owner = 'O',
  int gen = 3,
  String purpose = 'step-up',
}) => EnrollChallenge(
  token: _tok,
  ownerId: owner,
  keyId: key,
  generation: gen,
  challenge: 'C' * 43,
  actionDigest:
      digest ??
      approvalActionDigest(
        changeId: r.changeId,
        kind: r.kind,
        target: r.target,
        ownerId: 'O',
        generation: 3,
      ),
  expiresAt: exp,
  purpose: purpose,
);

void main() {
  test('new route allowlist: exact key sets, status takes an empty body', () {
    expect(deviceKeyRequestAllowed('/v1/manage/approval/status', {}), isTrue);
    expect(
      deviceKeyRequestAllowed('/v1/manage/approval/status', {'x': 1}),
      isFalse,
    );
    expect(
      deviceKeyRequestAllowed('/v1/manage/approval/approve-begin', {
        'changeId': 'c',
        'keyId': 'k',
      }),
      isTrue,
    );
    expect(
      deviceKeyRequestAllowed('/v1/manage/approval/approve-begin', {
        'changeId': 'c',
      }),
      isFalse,
    );
    expect(
      deviceKeyRequestAllowed('/v1/manage/device-key/add-begin', {
        'changeId': 'c',
      }),
      isTrue,
    );
    expect(
      deviceKeyRequestAllowed('/v1/manage/device-key/add-finish', {
        'changeId': 'c',
        'token': 't',
        'signature': 's',
      }),
      isTrue,
    );
    expect(
      deviceKeyRequestAllowed('/v1/manage/passkey/add/approval-request', {}),
      isFalse,
      reason: 'web-only route',
    );
  });

  test('status parser: exact fields, max 8 rows, bad shapes are null', () {
    expect(
      parseApprovalStatus(_status([_row(), _row(kind: 'device-key-add')]))!
          .pending,
      hasLength(2),
    );
    expect(parseApprovalStatus(_status([])), isNotNull);
    expect(
      parseApprovalStatus(_status(List.generate(9, (_) => _row()))),
      isNull,
    );
    expect(parseApprovalStatus({..._status([]), 'extra': 1}), isNull);
    expect(
      parseApprovalStatus(
        _status([
          {..._row(), 'jwk': 'x'},
        ]),
      ),
      isNull,
    );
    expect(parseApprovalStatus(_status([_row(kind: 'weird')])), isNull);
    expect(
      parseApprovalStatus(
        _status([_row(kind: 'device-key-add', target: 'short')]),
      ),
      isNull,
    );
    final pk = _row();
    pk['target'] = 'x';
    expect(
      parseApprovalStatus(_status([pk])),
      isNull,
      reason: 'passkey-add has no target',
    );
    expect(parseApprovalStatus(_status([_row(label: 'x' * 65)])), isNull);
    expect(
      parseApprovalStatus(_status([_row(label: null)]))!
          .pending
          .single
          .requesterLabel,
      isNull,
    );
    expect(parseApprovalStatus(null), isNull);
  });

  test('approval prompt only when owner, generation, purpose, own key, digest, lifetime and row all match', () {
    final st = parseApprovalStatus(_status([_row(kind: 'device-key-add')]))!;
    final row = st.pending.single;
    String? go(EnrollChallenge c, {int now = 1000}) =>
        validateApprovalChallenge(
          status: st,
          row: row,
          challenge: c,
          storedOwnerId: 'O',
          ownKeyId: 'K',
          accountEmail: 'me@x.io',
          nowMs: now,
        );
    final ok = go(_ch(row))!;
    expect(ok, contains(fingerprintOf(_digest)));
    expect(ok, contains('me@x.io'));
    expect(go(_ch(row, digest: 'a' * 64)), isNull, reason: 'digest');
    expect(go(_ch(row, owner: 'EVIL')), isNull);
    expect(go(_ch(row, gen: 4)), isNull);
    expect(go(_ch(row, key: 'OTHER')), isNull);
    expect(go(_ch(row, purpose: 'enroll')), isNull);
    expect(go(_ch(row, exp: 1000)), isNull, reason: 'expired');
    expect(go(_ch(row, exp: 1000 + 150001)), isNull, reason: 'too long');
    expect(
      go(_ch(row), now: 500000),
      isNull,
      reason: 'approval itself expired',
    );
    final far = parseApprovalStatus(
      _status([
        {
          ..._row(kind: 'device-key-add'),
          'requestedAt': 1001,
          'expiresAt': 1000 + 600001,
        },
      ]),
    )!;
    expect(
      validateApprovalChallenge(
        status: far,
        row: far.pending.single,
        challenge: _ch(far.pending.single),
        storedOwnerId: 'O',
        ownKeyId: 'K',
        accountEmail: 'a',
        nowMs: 1000,
      ),
      isNull,
      reason: 'approval expiry beyond now+600 s',
    );
    // A row that is not in the parsed status is never prompted.
    final other = parseApprovalStatus(_status([_row(kind: 'device-key-add')]))!
        .pending
        .single;
    expect(
      validateApprovalChallenge(
        status: st,
        row: other,
        challenge: _ch(other),
        storedOwnerId: 'O',
        ownKeyId: 'K',
        accountEmail: 'a',
        nowMs: 1000,
      ),
      isNull,
    );
    // passkey-add text uses the browser-session fallback and never a fingerprint.
    final pst = parseApprovalStatus(_status([_row(label: null)]))!;
    final prow = pst.pending.single;
    final t = validateApprovalChallenge(
      status: pst,
      row: prow,
      challenge: _ch(prow),
      storedOwnerId: 'O',
      ownKeyId: 'K',
      accountEmail: 'me@x.io',
      nowMs: 1000,
    );
    expect(t, contains('from a browser.'));
  });

  test('approver clients: typed results only', () async {
    Future<_R> post(String p, Map<String, dynamic> b) async => switch (p) {
      '/v1/manage/approval/status' => (status: 200, body: _status([_row()])),
      '/v1/manage/approval/approve-begin' => (
        status: 200,
        body: {
          'token': _tok,
          'challenge': {
            'ownerId': 'O',
            'keyId': 'K',
            'generation': 3,
            'purpose': 'step-up',
            'actionDigest': 'a' * 64,
            'challenge': 'C' * 43,
            'expiresAt': 9,
          },
        },
      ),
      _ => (status: 200, body: {'status': 'approved'}),
    };
    final r = ApprovalRoutes(post);
    expect((await r.status())!.pending, hasLength(1));
    expect((await r.approveBegin('C1', 'K'))!.purpose, 'step-up');
    expect(await r.approveFinish('C1', _tok, Uint8List(64)), isTrue);
    expect(
      await ApprovalRoutes(
        (p, b) async => (status: 200, body: {'status': 'ok'}),
      ).approveFinish('C1', _tok, Uint8List(64)),
      isFalse,
    );
    expect(
      await ApprovalRoutes((p, b) async => (status: 204, body: null))
          .approveFinish('C1', _tok, Uint8List(64)),
      isFalse,
    );
  });

  test(
    'add-request: the server fingerprint must equal the locally computed one',
    () async {
      Future<AddRequestReply?> go(Object? fp) => AddDeviceRoutes(
        (p, b) async => (
          status: 200,
          body: {'changeId': 'C1', 'expiresAt': 9, 'fingerprint': fp},
        ),
      ).addRequest(_jwk);
      expect(
        (await go(fingerprintOf(_digest)))!.fingerprint,
        fingerprintOf(_digest),
      );
      expect(await go('aaaa-bbbb-cccc-dddd'), isNull);
      expect(await go('AAAA-BBBB-CCCC-DDDD'), isNull);
      expect(await go(null), isNull);
      expect(
        fingerprintOf('0123456789abcdef${'0' * 48}'),
        '0123-4567-89ab-cdef',
      );
    },
  );

  test(
    'add-begin needs enroll purpose; add-finish counts only enrolled + keyId',
    () async {
      final good = {
        'token': _tok,
        'challenge': {
          'ownerId': 'O',
          'keyId': 'K',
          'generation': 1,
          'purpose': 'enroll',
          'actionDigest': 'a' * 64,
          'challenge': 'C' * 43,
          'expiresAt': 9,
        },
      };
      expect(
        (await AddDeviceRoutes((p, b) async => (status: 200, body: good))
                .addBegin('C1'))!
            .purpose,
        'enroll',
      );
      expect(
        await AddDeviceRoutes(
          (p, b) async => (status: 409, body: {'error': 'unavailable'}),
        ).addBegin('C1'),
        isNull,
      );
      final c = parseDeviceChallenge(good, 'enroll')!;
      expect(
        (await AddDeviceRoutes(
          (p, b) async =>
              (status: 200, body: {'status': 'enrolled', 'keyId': 'K'}),
        ).addFinish('C1', c, Uint8List(64))).keyId,
        'K',
      );
      expect(
        (await AddDeviceRoutes(
          (p, b) async => (status: 204, body: null),
        ).addFinish('C1', c, Uint8List(64))).keyId,
        isNull,
      );
    },
  );

  test('add pending record: strict state-specific decode; finishSent keeps the identical bytes', () {
    AddPendingRecord rec(
      AddState s, {
      String? tok,
      Uint8List? sig,
      int? sent,
      int? aexp,
      int? cexp,
    }) => AddPendingRecord(
      state: s,
      ownerId: 'O',
      sessionDeviceId: 'D',
      changeId: 'C1',
      digest: _digest,
      keyId: s == AddState.requested ? null : 'K',
      requestStartMs: 5,
      approvalExpiresAtMs: aexp,
      challengeExpiresAtMs: cexp,
      sentAtMs: sent,
      token: tok,
      signature: sig,
    );
    expect(
      AddPendingRecord.decode(rec(AddState.requested, aexp: 9).encode()),
      isNotNull,
    );
    expect(
      AddPendingRecord.decode(rec(AddState.requested).encode()),
      isNull,
      reason: 'requested needs approval expiry',
    );
    expect(
      AddPendingRecord.decode(rec(AddState.begun, cexp: 9).encode()),
      isNotNull,
    );
    final fin = rec(
      AddState.finishSent,
      tok: _tok,
      sig: Uint8List.fromList(List.filled(64, 7)),
      sent: 8,
      cexp: 9,
    );
    final back = AddPendingRecord.decode(fin.encode())!;
    expect(back.token, _tok);
    expect(back.signature, Uint8List.fromList(List.filled(64, 7)));
    expect(
      AddPendingRecord.decode(
        rec(
          AddState.finishSent,
          tok: _tok,
          sig: Uint8List(63),
          sent: 8,
          cexp: 9,
        ).encode(),
      ),
      isNull,
    );
    expect(
      AddPendingRecord.decode(rec(AddState.begun, tok: _tok, cexp: 9).encode()),
      isNull,
      reason: 'begun carries no token',
    );
    expect(AddPendingRecord.decode('{'), isNull);
    // The first-enrollment record never decodes as an add record, and vice versa.
    expect(AddPendingRecord.decode('{"v":1,"state":"begun"}'), isNull);
  });
}
