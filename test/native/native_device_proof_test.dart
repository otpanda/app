import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_device_proof.dart';

// Shared fixed vector (tool/android-recovery/fixtures/device-proof-vector.txt).
const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
const _message =
    'WyJvdHBhbmRhLWRldmljZS1wcm9vZi12MSIsInJlY292ZXItYWNjZXNzIiwib3duZXIiLCJrZXkiLDEsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwxODAwMDAwMTIwMDAwXQ==';

class _Src implements DeviceProofSource {
  DeviceProofAvailability avail = DeviceProofAvailability.available;
  DeviceProofFailure? createFail, signFail;
  Uint8List sig = Uint8List(64);
  int creates = 0, signs = 0;
  Uint8List? signed;
  @override
  Future<DeviceProofAvailability> availability() async => avail;
  @override
  Future<bool> hasKey() async => creates > 0;
  @override
  Future<Uint8List?> publicKeyOrNull() async =>
      creates > 0 ? base64.decode(_spki) : null;
  @override
  Future<Uint8List> createKeyForEnrollment() async {
    creates++;
    if (createFail != null) throw createFail!;
    return base64.decode(_spki);
  }

  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    signed = f.message;
    if (signFail != null) throw signFail!;
    return sig;
  }
}

final _tok = 'otpda_${'A' * 55}';

EnrollChallenge _ch({int expires = 100000, String? digest}) => EnrollChallenge(
  token: _tok,
  ownerId: 'owner',
  keyId: 'key',
  generation: 1,
  challenge: 'A' * 43,
  actionDigest:
      digest ?? deviceEnrollmentAction(spkiToJwk(base64.decode(_spki))),
  expiresAt: expires,
);

class _Store implements PendingEnrollStore {
  PendingRecord? rec;
  final writes = <PendingRecord>[];
  bool failWrites = false, cleared = false;
  @override
  Future<PendingRead> read() async =>
      rec == null ? const PendingRead.none() : PendingRead.record(rec!);
  @override
  Future<void> write(PendingRecord r) async {
    if (failWrites) throw Exception('disk');
    writes.add(r);
    rec = r;
  }

  @override
  Future<void> clear() async {
    cleared = true;
    rec = null;
  }
}

Future<EnrollmentResult> _enroll(
  DeviceProofSource s,
  EnrollmentServer srv, {
  int Function()? now,
  PendingEnrollStore? store,
  String owner = 'owner',
}) => enrollDevice(
  s,
  srv,
  expectedOwnerId: owner,
  sessionDeviceId: 'DEV',
  expectedGeneration: 1,
  store: store,
  now: now,
);

final _fields = DeviceProofFields(
  purpose: 'enroll',
  ownerId: 'owner',
  keyId: 'key',
  generation: 1,
  challenge: 'A' * 43,
  actionDigest: 'b' * 64,
  expiresAt: 5,
);

void main() {
  test('message bytes match the shared cross-language vector', () {
    final m = deviceProofMessage(
      purpose: 'recover-access',
      ownerId: 'owner',
      keyId: 'key',
      generation: 1,
      challenge: 'A' * 43,
      actionDigest: 'b' * 64,
      expiresAt: 1800000120000,
    );
    expect(base64.encode(m), _message);
  });

  test('message refuses bad fields and unknown purposes', () {
    Uint8List mk({String p = 'enroll', String d = 'b'}) => deviceProofMessage(
      purpose: p,
      ownerId: 'o',
      keyId: 'k',
      generation: 0,
      challenge: 'A' * 43,
      actionDigest: d * 64,
      expiresAt: 5,
    );
    expect(mk, returnsNormally);
    expect(() => mk(p: 'login'), throwsFormatException);
    expect(() => mk(d: 'B'), throwsFormatException);
  });

  test('SPKI becomes the exact JWK, anything else is refused', () {
    final j = spkiToJwk(base64.decode(_spki));
    expect(j.keys.toSet(), {'kty', 'crv', 'x', 'y'});
    expect(j['x'], 'f6D2ZU6KOMIilG_FwV5O17ameP6NzDCyEStU1W9XlRs');
    expect(j['y'], '2aAlm8vPsZfX2YkGTB0bpspRxvUx5GTdz9khawabvzQ');
    expect(() => spkiToJwk(Uint8List(91)), throwsFormatException);
    expect(() => spkiToJwk(Uint8List(65)), throwsFormatException);
  });

  test('platform codes map to stable failures; unknown is failed', () {
    expect(failureFromCode('cancelled').kind, DeviceProofFailureKind.cancelled);
    expect(
      failureFromCode('key_invalidated').kind,
      DeviceProofFailureKind.keyInvalidated,
    );
    expect(
      failureFromCode('no_secure_lock').kind,
      DeviceProofFailureKind.noSecureLock,
    );
    expect(
      failureFromCode('locked_out').kind,
      DeviceProofFailureKind.lockedOut,
    );
    expect(failureFromCode('weird').kind, DeviceProofFailureKind.failed);
    expect(failureFromCode(null).kind, DeviceProofFailureKind.failed);
  });

  test('channel source: missing host is unsupported, codes map, availability unknown never available', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const ch = MethodChannel('t/device-proof');
    final s = ChannelDeviceProofSource(ch);
    expect(await s.availability(), DeviceProofAvailability.unsupportedOs);
    await expectLater(
      s.hasKey(),
      throwsA(
        isA<DeviceProofFailure>().having(
          (e) => e.kind,
          'kind',
          DeviceProofFailureKind.unsupportedOs,
        ),
      ),
    );
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (c) async {
          if (c.method == 'availability') return 'surprise';
          throw PlatformException(code: 'key_invalidated');
        });
    expect(await s.availability(), DeviceProofAvailability.unknown);
    await expectLater(
      s.sign(_fields),
      throwsA(
        isA<DeviceProofFailure>().having(
          (e) => e.kind,
          'kind',
          DeviceProofFailureKind.keyInvalidated,
        ),
      ),
    );
  });

  test(
    'enroll: available, key, begin, OS signature over exact bytes, finish 200',
    () async {
      final s = _Src();
      Map<String, String>? sent;
      final r = await _enroll(
        s,
        EnrollmentServer(
          begin: (jwk) async {
            sent = jwk;
            return _ch();
          },
          finish: (c, sig) async =>
              const EnrollFinishResponse(200, keyId: 'key'),
        ),
        now: () => 1000,
      );
      expect(r.outcome, EnrollmentOutcome.enrolled);
      expect(sent!['kty'], 'EC');
      expect(
        utf8.decode(s.signed!),
        startsWith('["otpanda-device-proof-v1","enroll","owner","key",1,'),
      );
    },
  );

  test(
    'enroll never starts without API 30 or a secure lock, and makes no key',
    () async {
      for (final a in [
        DeviceProofAvailability.unsupportedOs,
        DeviceProofAvailability.noSecureLock,
        DeviceProofAvailability.unknown,
      ]) {
        final s = _Src()..avail = a;
        final r = await _enroll(
          s,
          EnrollmentServer(
            begin: (_) async => _ch(),
            finish: (c, g) async =>
                const EnrollFinishResponse(200, keyId: 'key'),
          ),
        );
        expect(r.outcome, EnrollmentOutcome.notStarted);
        expect(s.creates, 0);
      }
    },
  );

  test(
    'finish 409 is opaque: unknown with pending, never methodExists; key kept',
    () async {
      final s = _Src();
      final r = await _enroll(
        s,
        EnrollmentServer(
          begin: (_) async => _ch(),
          finish: (c, g) async => const EnrollFinishResponse(409),
        ),
        now: () => 1,
      );
      expect(r.outcome, EnrollmentOutcome.unknown);
      expect(r.publicKeyDigest, isNotEmpty);
      expect(r.pending, isNotNull);
      expect(s.creates, 1);
    },
  );

  test('begin method_exists vs opaque 409: only the first offers existing-method sign-in', () async {
    final s = _Src();
    final e = await _enroll(
      s,
      EnrollmentServer(
        begin: (_) async => throw const EnrollBeginMethodExists(),
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
      now: () => 1,
    );
    expect(e.outcome, EnrollmentOutcome.methodExists);
    expect(s.signs, 0);
    final o = await _enroll(
      s,
      EnrollmentServer(
        begin: (_) async => throw const EnrollBeginOpaque(),
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
      now: () => 1,
    );
    expect(o.outcome, EnrollmentOutcome.unknown);
    expect(o.publicKeyDigest, isNotEmpty);
    expect(s.signs, 0);
  });

  test(
    'a lost or ambiguous response is unknown, not rejected and not cleanup',
    () async {
      for (final f
          in <
            Future<EnrollFinishResponse> Function(EnrollChallenge, Uint8List)
          >[
            (c, g) async => throw Exception('timeout'),
            (c, g) async => const EnrollFinishResponse(503),
            (c, g) async => const EnrollFinishResponse(500),
          ]) {
        final s = _Src();
        final r = await _enroll(
          s,
          EnrollmentServer(begin: (_) async => _ch(), finish: f),
          now: () => 1,
        );
        expect(r.outcome, EnrollmentOutcome.unknown);
      }
      final s = _Src();
      final r = await _enroll(
        s,
        EnrollmentServer(
          begin: (_) async => throw Exception('net'),
          finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
        ),
      );
      expect(r.outcome, EnrollmentOutcome.unknown);
      expect(s.signs, 0);
    },
  );

  test('cancelled prompt sends nothing; expired challenge never prompts; bad signature length is refused', () async {
    var finishes = 0;
    final srv = EnrollmentServer(
      begin: (_) async => _ch(),
      finish: (c, g) async {
        finishes++;
        return const EnrollFinishResponse(200, keyId: 'key');
      },
    );
    final s = _Src()
      ..signFail = const DeviceProofFailure(DeviceProofFailureKind.cancelled);
    var r = await _enroll(s, srv, now: () => 1);
    expect(
      (r.outcome, r.failure!.kind),
      (EnrollmentOutcome.rejected, DeviceProofFailureKind.cancelled),
    );
    final e = _Src();
    r = await _enroll(
      e,
      EnrollmentServer(
        begin: (_) async => _ch(expires: 5),
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
      now: () => 10,
    );
    expect(r.failure!.kind, DeviceProofFailureKind.expired);
    expect(e.signs, 0);
    final b = _Src()..sig = Uint8List(70);
    r = await _enroll(b, srv, now: () => 1);
    expect(r.outcome, EnrollmentOutcome.rejected);
    expect(finishes, 0);
  });

  test('key creation failure is notStarted with the mapped reason', () async {
    final s = _Src()
      ..createFail = const DeviceProofFailure(
        DeviceProofFailureKind.noSecureLock,
      );
    final r = await _enroll(
      s,
      EnrollmentServer(
        begin: (_) async => _ch(),
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
    );
    expect(
      (r.outcome, r.failure!.kind),
      (EnrollmentOutcome.notStarted, DeviceProofFailureKind.noSecureLock),
    );
  });

  test('only a 200 with the challenge keyId is enrolled; 201, 204, empty and mismatched keyId are not', () async {
    for (final r in const [
      EnrollFinishResponse(200),
      EnrollFinishResponse(200, keyId: 'other'),
      EnrollFinishResponse(200, keyId: '../x'),
      EnrollFinishResponse(201, keyId: 'key'),
      EnrollFinishResponse(204),
    ]) {
      final res = await _enroll(
        _Src(),
        EnrollmentServer(begin: (_) async => _ch(), finish: (c, g) async => r),
        now: () => 1,
      );
      expect(
        res.outcome,
        EnrollmentOutcome.unknown,
        reason: '${r.status} ${r.keyId}',
      );
      expect(res.keyId, isNull);
      expect(res.pending, isNotNull);
    }
    final ok = await _enroll(
      _Src(),
      EnrollmentServer(
        begin: (_) async => _ch(),
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
      now: () => 1,
    );
    expect((ok.outcome, ok.keyId), (EnrollmentOutcome.enrolled, 'key'));
    expect(ok.publicKeyDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
  });

  test('a 4xx other than 409 is rejected, not unknown', () async {
    final res = await _enroll(
      _Src(),
      EnrollmentServer(
        begin: (_) async => _ch(),
        finish: (c, g) async => const EnrollFinishResponse(401),
      ),
      now: () => 1,
    );
    expect(res.outcome, EnrollmentOutcome.rejected);
  });

  test('lost response: identical finish retried byte for byte with no new prompt, only inside the receipt window', () async {
    final s = _Src();
    final seen = <(String, List<int>)>[];
    var lose = true;
    final srv = EnrollmentServer(
      begin: (_) async => _ch(),
      finish: (c, g) async {
        seen.add((c.token, List.of(g)));
        if (lose) throw Exception('lost');
        return const EnrollFinishResponse(200, keyId: 'key');
      },
    );
    final first = await _enroll(s, srv, now: () => 1000);
    expect(first.outcome, EnrollmentOutcome.unknown);
    lose = false;
    final again = await retryEnrollFinish(
      first.pending!,
      srv,
      now: () => 1000 + 599999,
    );
    expect(again.outcome, EnrollmentOutcome.enrolled);
    expect(seen[0].$1, seen[1].$1);
    expect(seen[0].$2, seen[1].$2);
    expect(s.signs, 1, reason: 'no second OS prompt');
    expect(first.publicKeyDigest, isNotEmpty);
    expect(again.publicKeyDigest, first.publicKeyDigest);
    final late = await retryEnrollFinish(
      first.pending!,
      srv,
      now: () => 1000 + 600000,
    );
    expect(late.outcome, EnrollmentOutcome.unknown);
    expect(late.publicKeyDigest, first.publicKeyDigest);
    expect(seen.length, 2, reason: 'past the window it sends nothing');
  });

  test(
    'public key digest is the SHA-256 of the canonical JWK JSON in key order',
    () {
      final j = spkiToJwk(base64.decode(_spki));
      expect(publicKeyDigest(j), matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        publicKeyDigest(j),
        publicKeyDigest({
          'y': j['y']!,
          'x': j['x']!,
          'crv': 'P-256',
          'kty': 'EC',
        }),
      );
      expect(publicKeyDigest(j), isNot(publicKeyDigest({...j, 'x': j['y']!})));
    },
  );

  test('reconcile: floor is max(request start + 120 s, challenge expiry); no early absent', () {
    int d(ServerKeyStatus st, {int? exp, required int now}) => decideReconcile(
      st,
      requestStartMs: 1000,
      beginExpiresAt: exp,
      now: now,
    ).index;
    const adopt = ReconcileAction.adopt, wait = ReconcileAction.waitForExpiry;
    const regrant = ReconcileAction.keepKeyAndRegrant;
    expect(d(ServerKeyStatus.enrolled, now: 1), adopt.index);
    expect(
      d(ServerKeyStatus.revoked, now: 1),
      ReconcileAction.createNewKey.index,
    );
    // Lost begin (no expiry known): wait the full 120 s from the START.
    expect(d(ServerKeyStatus.absent, now: 1000 + 120000), wait.index);
    expect(d(ServerKeyStatus.absent, now: 1000 + 120001), regrant.index);
    // Challenge expiry later than start+120s wins.
    expect(d(ServerKeyStatus.absent, exp: 200000, now: 200000), wait.index);
    expect(d(ServerKeyStatus.absent, exp: 200000, now: 200001), regrant.index);
    // Challenge expiry earlier than start+120s does not shorten the wait.
    expect(d(ServerKeyStatus.absent, exp: 5000, now: 50000), wait.index);
    expect(absentFloorMs(1000, null), 121000);
  });

  test(
    'begin 429/5xx is retryLater with the key kept; a lost begin is unknown',
    () async {
      final s = _Src();
      final r1 = await _enroll(
        s,
        EnrollmentServer(
          begin: (_) async => throw const EnrollBeginTransient(),
          finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
        ),
        now: () => 1000,
      );
      expect(r1.outcome, EnrollmentOutcome.retryLater);
      expect(r1.publicKeyDigest, isNotEmpty);
      expect(s.signs, 0);
      final r2 = await _enroll(
        s,
        EnrollmentServer(
          begin: (_) async => throw Exception('lost'),
          finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
        ),
        now: () => 1000,
      );
      expect(r2.outcome, EnrollmentOutcome.unknown);
    },
  );

  test(
    'temporarily unavailable hardware is its own failure, not no_secure_lock',
    () async {
      final s = _Src()..avail = DeviceProofAvailability.temporarilyUnavailable;
      final r = await _enroll(
        s,
        EnrollmentServer(
          begin: (_) async => _ch(),
          finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
        ),
        now: () => 1000,
      );
      expect(r.outcome, EnrollmentOutcome.notStarted);
      expect(r.failure!.kind, DeviceProofFailureKind.temporarilyUnavailable);
      expect(s.creates, 0);
      expect(
        failureFromCode('temporarily_unavailable').kind,
        DeviceProofFailureKind.temporarilyUnavailable,
      );
    },
  );

  test('finish 429 keeps the identical pending finish: no rejection, no second prompt', () async {
    final s = _Src();
    var n = 0;
    final srv = EnrollmentServer(
      begin: (_) async => _ch(),
      finish: (c, g) async => n++ == 0
          ? const EnrollFinishResponse(429)
          : const EnrollFinishResponse(200, keyId: 'key'),
    );
    final r = await _enroll(s, srv, now: () => 1000);
    expect(r.outcome, EnrollmentOutcome.unknown);
    final again = await retryEnrollFinish(r.pending!, srv, now: () => 2000);
    expect(again.outcome, EnrollmentOutcome.enrolled);
    expect(s.signs, 1);
  });

  test('enroll validates digest, owner, generation and lifetime BEFORE any signature', () async {
    EnrollmentServer srvFor(EnrollChallenge c) => EnrollmentServer(
      begin: (_) async => c,
      finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
    );
    final cases = <EnrollChallenge>[
      _ch(digest: 'b' * 64), // arbitrary server digest
      EnrollChallenge(
        token: _tok,
        ownerId: 'someone-else',
        keyId: 'key',
        generation: 1,
        challenge: 'A' * 43,
        actionDigest: _ch().actionDigest,
        expiresAt: 100000,
      ),
      EnrollChallenge(
        token: _tok,
        ownerId: 'owner',
        keyId: 'key',
        generation: 2,
        challenge: 'A' * 43,
        actionDigest: _ch().actionDigest,
        expiresAt: 100000,
      ),
      EnrollChallenge(
        token: _tok,
        ownerId: 'owner',
        keyId: '',
        generation: 1,
        challenge: 'A' * 43,
        actionDigest: _ch().actionDigest,
        expiresAt: 100000,
      ),
      _ch(expires: 1000 + 150001), // too long
      _ch(expires: 1000), // already expired
    ];
    for (final c in cases) {
      final s = _Src();
      final r = await _enroll(s, srvFor(c), now: () => 1000);
      expect(r.outcome, EnrollmentOutcome.rejected);
      expect(
        s.signs,
        0,
        reason: 'no OS prompt for ${c.ownerId}/${c.expiresAt}',
      );
    }
    final s = _Src();
    final ok = await _enroll(
      s,
      srvFor(_ch(expires: 1000 + 150000)),
      now: () => 1000,
    );
    expect(ok.outcome, EnrollmentOutcome.enrolled);
    expect(s.signs, 1);
    // digest equals deviceEnrollmentAction of OUR key
    expect(_ch().actionDigest, hasLength(64));
  });

  test('pending store: begun before begin, finishSent (token+signature) before finish, cleared only on enrolled', () async {
    final st = _Store();
    var seenBeforeBegin = false, seenBeforeFinish = false;
    final s = _Src();
    final r = await _enroll(
      s,
      EnrollmentServer(
        begin: (_) async {
          seenBeforeBegin =
              st.rec?.state == PendingState.begun &&
              st.rec!.requestStartMs == 1000;
          return _ch();
        },
        finish: (c, g) async {
          seenBeforeFinish =
              st.rec?.state == PendingState.finishSent &&
              st.rec!.token == _tok &&
              st.rec!.signature!.length == 64;
          throw Exception('lost');
        },
      ),
      now: () => 1000,
      store: st,
    );
    expect(seenBeforeBegin && seenBeforeFinish, isTrue);
    expect(r.outcome, EnrollmentOutcome.unknown);
    expect(st.cleared, isFalse, reason: 'unknown never clears');
    // Survives process death: decode what was stored.
    final back = PendingRecord.decode(st.rec!.encode())!;
    expect(back.requestStartMs, 1000);
    expect(back.keyId, 'key');
    expect(back.signature, st.rec!.signature);
    expect(back.token, _tok);
    // Success clears.
    final st2 = _Store();
    await _enroll(
      _Src(),
      EnrollmentServer(
        begin: (_) async => _ch(),
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
      now: () => 1000,
      store: st2,
    );
    expect(st2.cleared, isTrue);
  });

  test(
    'a lost begin keeps the request start so absent cannot be trusted early',
    () async {
      final st = _Store();
      final r = await _enroll(
        _Src(),
        EnrollmentServer(
          begin: (_) async => throw Exception('lost'),
          finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
        ),
        now: () => 5000,
        store: st,
      );
      expect(r.outcome, EnrollmentOutcome.unknown);
      final rec = PendingRecord.decode(st.rec!.encode())!;
      expect(rec.state, PendingState.begun);
      expect(rec.expiresAtMs, isNull);
      expect(
        decideReconcile(
          ServerKeyStatus.absent,
          requestStartMs: rec.requestStartMs,
          now: 5000 + 60000,
        ),
        ReconcileAction.waitForExpiry,
      );
    },
  );

  test('a store write failure stops the network step; garbage records decode to null', () async {
    final st = _Store()..failWrites = true;
    var begins = 0;
    final r = await _enroll(
      _Src(),
      EnrollmentServer(
        begin: (_) async {
          begins++;
          return _ch();
        },
        finish: (c, g) async => const EnrollFinishResponse(200, keyId: 'key'),
      ),
      now: () => 1000,
      store: st,
    );
    expect(r.outcome, EnrollmentOutcome.notStarted);
    expect(begins, 0);
    expect(PendingRecord.decode('{'), isNull);
    expect(PendingRecord.decode('{"v":2}'), isNull);
    expect(PendingRecord.decode(null), isNull);
  });

  test('channel sign passes displayText only when given', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const ch = MethodChannel('app.otpanda/device-proof');
    final calls = <Map<Object?, Object?>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (c) async {
          calls.add(Map<Object?, Object?>.from(c.arguments as Map));
          return Uint8List(64);
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null),
    );
    final src = ChannelDeviceProofSource(ch);
    await src.sign(_fields);
    await src.sign(_fields, displayText: 'Assign this code to Work.');
    expect(calls[0].containsKey('displayText'), isFalse);
    expect(calls[1]['displayText'], 'Assign this code to Work.');
  });
}
