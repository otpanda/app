import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_routes.dart';
import 'package:otpanda_client/native/native_enroll_recovery.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
final _tok = 'otpda_${'A' * 55}';
final _grant = 'otpda_${'G' * 55}';
final _jwk = spkiToJwk(base64.decode(_spki));
final _digest = publicKeyDigest(_jwk);

class _Src implements DeviceProofSource {
  bool key = true;
  int signs = 0, creates = 0;
  @override
  Future<Uint8List?> publicKeyOrNull() async =>
      key ? base64.decode(_spki) : null;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => key;
  @override
  Future<Uint8List> createKeyForEnrollment() async {
    creates++;
    return base64.decode(_spki);
  }

  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    return Uint8List(64);
  }
}

class _Store implements PendingEnrollStore {
  _Store(this.state);
  PendingRead state;
  bool cleared = false;
  @override
  Future<PendingRead> read() async => state;
  @override
  Future<void> write(PendingRecord r) async => state = PendingRead.record(r);
  @override
  Future<void> clear() async {
    cleared = true;
    state = const PendingRead.none();
  }
}

class _FailStore extends _Store {
  _FailStore(super.state);
  @override
  Future<void> write(PendingRecord r) async => throw Exception('disk');
}

PendingRecord _rec({
  PendingState st = PendingState.begun,
  String owner = 'O',
  String dev = 'D',
  int start = 1000,
  int? exp,
  int? sent,
}) => PendingRecord(
  state: st,
  digest: _digest,
  requestStartMs: start,
  ownerId: owner,
  sessionDeviceId: dev,
  keyId: st == PendingState.keyCreated ? null : 'KID',
  expiresAtMs: exp,
  sentAtMs: st == PendingState.finishSent ? (sent ?? 2000) : null,
  token: st == PendingState.finishSent ? _tok : null,
  signature: st == PendingState.finishSent ? Uint8List(64) : null,
);

typedef _Resp = ({int status, Map<String, dynamic>? body});

Future<RecoveryResult> _run(
  _Store st,
  Map<String, _Resp> routes,
  int now, {
  List<String>? log,
  _Src? src,
  String owner = 'O',
  String dev = 'D',
  List<String>? confirmed,
}) {
  Future<_Resp> post(String p, Map<String, dynamic> b) async {
    log?.add(p);
    return routes[p] ?? (status: 503, body: null);
  }

  return recoverEnrollment(
    store: st,
    source: src ?? _Src(),
    enrollRoutes: DeviceEnrollRoutes(post, grant: _grant),
    statusRoutes: DeviceStatusRoutes(post),
    ownerId: owner,
    sessionDeviceId: dev,
    onEnrolled: (k) async => confirmed?.add(k),
    now: () => now,
  );
}

const _stat = '/v1/manage/device-key/enroll-status';
const _fin = '/v1/manage/device-key/enroll-finish';

void main() {
  test('request allowlist: exact paths and key sets, no query, 4096 bytes', () {
    expect(deviceKeyRequestAllowed(_stat, {'digest': _digest}), isTrue);
    expect(deviceKeyRequestAllowed('$_stat?x=1', {'digest': _digest}), isFalse);
    expect(
      deviceKeyRequestAllowed(_stat, {'digest': _digest, 'x': 1}),
      isFalse,
    );
    expect(deviceKeyRequestAllowed(_stat, {}), isFalse);
    expect(
      deviceKeyRequestAllowed('/v1/manage/device-key/revoke', {'digest': 'x'}),
      isFalse,
    );
    expect(
      deviceKeyRequestAllowed(_fin, {
        'grant': 'g',
        'token': 't',
        'signature': 's',
      }),
      isTrue,
    );
    expect(
      deviceKeyRequestAllowed(_fin, {
        'grant': 'g',
        'token': 't',
        'signature': 'a' * 5000,
      }),
      isFalse,
    );
  });

  test('status parser: only a well-formed 200 counts; garbage is null, never absent', () async {
    Future<({ServerKeyStatus status, String? keyId})?> go(_Resp r) =>
        DeviceStatusRoutes((p, b) async => r).status(_digest);
    expect(
      (await go((status: 200, body: {'status': 'absent'})))!.status,
      ServerKeyStatus.absent,
    );
    expect(
      (await go((status: 200, body: {'status': 'enrolled', 'keyId': 'K'})))!
          .keyId,
      'K',
    );
    expect(await go((status: 200, body: {'status': 'enrolled'})), isNull);
    expect(await go((status: 200, body: {'status': 'nope'})), isNull);
    expect(await go((status: 409, body: {'error': 'unavailable'})), isNull);
    expect(await go((status: 200, body: null)), isNull);
  });

  test('begin parser: strict challenge; method_exists vs opaque 409; 429/5xx transient', () async {
    final ch = {
      'token': _tok,
      'challenge': {
        'ownerId': 'O',
        'keyId': 'K',
        'generation': 1,
        'purpose': 'enroll',
        'actionDigest': 'a' * 64,
        'challenge': 'C' * 43,
        'expiresAt': 5,
      },
    };
    Future<EnrollChallenge?> go(_Resp r) => DeviceEnrollRoutes(
      (p, b) async => r,
      grant: _grant,
    ).enrollment.begin(_jwk);
    expect((await go((status: 200, body: ch)))!.keyId, 'K');
    final bad = jsonDecode(jsonEncode(ch)) as Map<String, dynamic>;
    (bad['challenge'] as Map)['purpose'] = 'step-up';
    await expectLater(
      go((status: 200, body: bad)),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      go((status: 409, body: {'error': 'method_exists'})),
      throwsA(isA<EnrollBeginMethodExists>()),
    );
    await expectLater(
      go((status: 409, body: {'error': 'unavailable'})),
      throwsA(isA<EnrollBeginOpaque>()),
    );
    await expectLater(
      go((status: 429, body: null)),
      throwsA(isA<EnrollBeginTransient>()),
    );
    await expectLater(
      go((status: 503, body: null)),
      throwsA(isA<EnrollBeginTransient>()),
    );
    expect(await go((status: 401, body: null)), isNull);
  });

  test(
    'finish parser: only {status:enrolled,keyId} on 200 carries a keyId',
    () async {
      Future<EnrollFinishResponse> go(_Resp r) =>
          DeviceEnrollRoutes(
            (p, b) async => r,
            grant: _grant,
          ).enrollment.finish(
            EnrollChallenge(
              token: _tok,
              ownerId: 'O',
              keyId: 'K',
              generation: 1,
              challenge: '',
              actionDigest: '',
              expiresAt: 1,
            ),
            Uint8List(64),
          );
      expect(
        (await go((status: 200, body: {'status': 'enrolled', 'keyId': 'K'})))
            .keyId,
        'K',
      );
      expect(
        (await go((status: 200, body: {'status': 'other', 'keyId': 'K'})))
            .keyId,
        isNull,
      );
      expect((await go((status: 204, body: null))).keyId, isNull);
    },
  );

  test('recovery: no record is nothing; foreign owner is kept untouched; unreadable is reconciled by possession', () async {
    expect(
      (await _run(_Store(const PendingRead.none()), {}, 1)).outcome,
      RecoveryOutcome.nothing,
    );
    final foreign = _Store(PendingRead.record(_rec(owner: 'OTHER')));
    final log = <String>[];
    expect(
      (await _run(foreign, {}, 1, log: log)).outcome,
      RecoveryOutcome.foreignRecord,
    );
    expect(log, isEmpty);
    expect(foreign.cleared, isFalse);
    final bad = _Store(const PendingRead.unreadable());
    final src = _Src();
    final r = await _run(
      bad,
      {
        _stat: (status: 200, body: {'status': 'absent'}),
      },
      50000,
      src: src,
    );
    expect(r.outcome, RecoveryOutcome.waiting);
    expect(r.waitUntilMs, 50000 + 120000);
    expect(src.creates, 0, reason: 'recovery only reads the public key');
    final saved = bad.state.record!;
    expect(saved.state, PendingState.begun);
    expect(saved.requestStartMs, 50000);
    expect(saved.ownerId, 'O');
    expect(saved.sessionDeviceId, 'D');
    expect(saved.digest, _digest);
    final noKey = await _run(
      _Store(const PendingRead.unreadable()),
      {},
      1,
      src: _Src()..key = false,
    );
    expect(noKey.outcome, RecoveryOutcome.unknown);
    expect(bad.cleared, isFalse);
    // Write failure: unknown, nothing sent.
    final failing = _FailStore(const PendingRead.unreadable());
    final log3 = <String>[];
    final f = await _run(
      failing,
      {
        _stat: (status: 200, body: {'status': 'absent'}),
      },
      1,
      log: log3,
    );
    expect(f.outcome, RecoveryOutcome.unknown);
    expect(log3, isEmpty);
  });

  test('recovery: finishSent in this session retries the identical finish; a typed matching 200 confirms natively then clears', () async {
    final st = _Store(
      PendingRead.record(
        _rec(st: PendingState.finishSent, exp: 9000, sent: 2000),
      ),
    );
    final confirmed = <String>[];
    final log = <String>[];
    final r = await _run(
      st,
      {
        _fin: (status: 200, body: {'status': 'enrolled', 'keyId': 'KID'}),
      },
      3000,
      log: log,
      confirmed: confirmed,
    );
    expect(r.outcome, RecoveryOutcome.enrolled);
    expect(confirmed, ['KID']);
    expect(st.cleared, isTrue);
    expect(log, [_fin]);
  });

  test('recovery: finish older than 10 min, another session, or mismatched keyId goes to status, state kept', () async {
    final old = _Store(
      PendingRead.record(
        _rec(st: PendingState.finishSent, exp: 9000, sent: 2000),
      ),
    );
    final log = <String>[];
    var r = await _run(
      old,
      {
        _stat: (status: 200, body: {'status': 'enrolled', 'keyId': 'KID'}),
      },
      2000 + 600000,
      log: log,
    );
    expect(r.outcome, RecoveryOutcome.needsAdopt);
    expect(log, [_stat], reason: 'no resend after the receipt window');
    final other = _Store(
      PendingRead.record(
        _rec(st: PendingState.finishSent, dev: 'OLD', exp: 9000),
      ),
    );
    final log2 = <String>[];
    await _run(
      other,
      {
        _stat: (status: 200, body: {'status': 'absent'}),
      },
      3000,
      log: log2,
    );
    expect(log2, [
      _stat,
    ], reason: 'a token from another session is never resent');
    final wrong = _Store(
      PendingRead.record(_rec(st: PendingState.finishSent, exp: 9000)),
    );
    final confirmed = <String>[];
    r = await _run(
      wrong,
      {
        _fin: (status: 200, body: {'status': 'enrolled', 'keyId': 'DIFFERENT'}),
        _stat: (status: 200, body: {'status': 'absent'}),
      },
      3000,
      confirmed: confirmed,
    );
    expect(confirmed, isEmpty);
    expect(wrong.cleared, isFalse);
  });

  test('recovery status rules: absent waits until max(start+120s, expiry), then regrants the SAME key; revoked needs a method; unreadable status is unknown', () async {
    Future<RecoveryResult> at(int now, {int? exp}) =>
        _run(_Store(PendingRead.record(_rec(start: 1000, exp: exp))), {
          _stat: (status: 200, body: {'status': 'absent'}),
        }, now);
    expect((await at(121000)).outcome, RecoveryOutcome.waiting);
    expect((await at(121001)).outcome, RecoveryOutcome.regrant);
    expect((await at(150000, exp: 200000)).outcome, RecoveryOutcome.waiting);
    expect((await at(200001, exp: 200000)).outcome, RecoveryOutcome.regrant);
    final st = _Store(PendingRead.record(_rec()));
    expect(
      (await _run(st, {
        _stat: (status: 200, body: {'status': 'revoked'}),
      }, 1)).outcome,
      RecoveryOutcome.revokedNeedsMethod,
    );
    expect(
      (await _run(st, {
        _stat: (status: 409, body: {'error': 'unavailable'}),
      }, 1)).outcome,
      RecoveryOutcome.unknown,
    );
    expect(st.cleared, isFalse);
  });

  test('pending decode: finishSent needs token shape, 64-byte signature, keyId, sent time; other states carry none', () {
    final good = _rec(st: PendingState.finishSent, exp: 5).encode();
    expect(PendingRecord.decode(good), isNotNull);
    Map<String, dynamic> m() => jsonDecode(good) as Map<String, dynamic>;
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (x) => x['sig'] = base64Url.encode(Uint8List(63)),
      (x) => x.remove('sig'),
      (x) => x['token'] = 'T',
      (x) => x.remove('token'),
      (x) => x.remove('keyId'),
      (x) => x.remove('sent'),
      (x) => x.remove('owner'),
      (x) => x['digest'] = 'XYZ',
      (x) => x['state'] = 'begun',
    ]) {
      final x = m();
      mutate(x);
      expect(PendingRecord.decode(jsonEncode(x)), isNull);
    }
  });

  test('unreadable record: two starts 121 s apart regrant instead of resetting the floor forever', () async {
    final st = _Store(const PendingRead.unreadable());
    final absent = {
      _stat: (status: 200, body: {'status': 'absent'}),
    };
    final first = await _run(st, absent, 10000);
    expect(first.outcome, RecoveryOutcome.waiting);
    final second = await _run(st, absent, 10000 + 121000);
    expect(second.outcome, RecoveryOutcome.regrant);
  });

  test('without the in-memory grant (process death) the finish is never replayed: status only', () async {
    final st = _Store(
      PendingRead.record(
        _rec(st: PendingState.finishSent, exp: 9000, sent: 2000),
      ),
    );
    final log = <String>[];
    Future<_Resp> post(String p, Map<String, dynamic> b) async {
      log.add(p);
      return (status: 200, body: {'status': 'enrolled', 'keyId': 'KID'});
    }

    final r = await recoverEnrollment(
      store: st,
      source: _Src(),
      enrollRoutes: null,
      statusRoutes: DeviceStatusRoutes(post),
      ownerId: 'O',
      sessionDeviceId: 'D',
      onEnrolled: (_) async {},
      now: () => 3000,
    );
    expect(r.outcome, RecoveryOutcome.needsAdopt);
    expect(log, [_stat]);
    expect(st.cleared, isFalse);
  });
}
