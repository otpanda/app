import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/seed_sync_http.dart';

typedef R = ({int status, Map<String, dynamic>? body});

final token = 'otpda_${'T' * 55}';
final nonce = 'A' * 43;
final sig = 'S' * 86;
final keyId = 'a' * 32;
final ephRaw = [4, ...List.filled(64, 7)];
final eph = base64UrlEncode(ephRaw).replaceAll('=', '');
final serverKey = base64UrlEncode([4, ...List.filled(64, 9)])
    .replaceAll('=', '');
final nonce12 = base64UrlEncode(List.filled(12, 3)).replaceAll('=', '');
final ct = base64UrlEncode(List.filled(26, 5)).replaceAll('=', '');

Map<String, dynamic> snapChallenge({
  String owner = 'owner',
  String key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  int epoch = 4,
}) => {
  'token': token,
  'challenge': {
    'ownerId': owner,
    'keyId': key,
    'deviceId': 'dev',
    'generation': 2,
    'epoch': epoch,
    'challenge': nonce,
    'expiresAt': 1800000120000,
  },
};

Map<String, dynamic> entry(String id, int v) => {
  'entryId': id,
  'seedVersion': v,
  'algorithm': 'SHA-1',
  'digits': 6,
  'period': 30,
};

Map<String, dynamic> snapBody({
  List<Object?>? entries,
  List<Object?>? unsupported,
  List<Object?>? tombstones,
  Map<String, Object?> over = const {},
}) => {
  'ownerId': 'owner',
  'deviceId': 'dev',
  'epoch': 4,
  'challengeDigest': sha256HexOf(nonce),
  'revision': 9,
  'complete': true,
  'maxBatch': 3,
  'entries': entries ?? [entry('a', 5)],
  'unsupported': unsupported ?? [],
  'tombstones': tombstones ?? [],
  ...over,
};

class Fake {
  final sent = <(String, Map<String, dynamic>)>[];
  final replies = <R>[];
  Future<R> post(String path, Map<String, dynamic> body) async {
    sent.add((path, body));
    return replies.removeAt(0);
  }
}

R ok(Map<String, dynamic> b) => (status: 200, body: b);

Future<SeedSyncChallenge> challenge(SeedSyncHttp h, Fake f) async {
  f.replies.add(ok(snapChallenge()));
  return h.snapshotBegin(keyId: keyId, epoch: 4);
}

Future<SeedSyncChallenge> batchChallenge(
  SeedSyncHttp h,
  Fake f, {
  Map<String, Object?> over = const {},
  Map<String, Object?> chOver = const {},
}) async {
  final entries = [
    (entryId: 'b', seedVersion: 2),
    (entryId: 'a', seedVersion: 5),
  ];
  final c = snapChallenge();
  (c['challenge'] as Map<String, dynamic>)
    ..['ephemeralDigest'] = sha256HexOfBytes(ephRaw)
    ..['entriesDigest'] = sha256HexOf(
      jsonEncode([
        ['a', 5],
        ['b', 2],
      ]),
    );
  chOver.forEach((k, v) => (c['challenge'] as Map<String, dynamic>)[k] = v);
  f.replies.add(ok({...c, ...over}));
  return h.batchBegin(
    keyId: keyId,
    epoch: 4,
    ephemeralKey: eph,
    entries: entries,
  );
}

Matcher failsWith(SeedSyncPullFailure r) =>
    throwsA(isA<SeedSyncPullException>().having((e) => e.reason, 'reason', r));

void main() {
  test('request key sets are exact and the allowlist is closed', () {
    expect(
      seedSyncPullRequestAllowed('snapshot-begin', {'epoch': 1, 'keyId': 'k'}),
      isTrue,
    );
    expect(seedSyncPullRequestAllowed('snapshot-begin', {'epoch': 1}), isFalse);
    expect(
      seedSyncPullRequestAllowed('snapshot-begin', {
        'epoch': 1,
        'keyId': 'k',
        'x': 1,
      }),
      isFalse,
    );
    expect(seedSyncPullRequestAllowed('revoke-begin', {'keyId': 'k'}), isFalse);
    expect(
      seedSyncPullRequestAllowed('batch-finish', {
        'token': 't',
        'signature': 's',
      }),
      isTrue,
    );
    expect(
      seedSyncPullRequestAllowed('batch-begin', {
        'entries': [],
        'ephemeralKey': 'e',
        'epoch': 1,
        'keyId': 'k',
      }),
      isTrue,
    );
  });

  test(
    'snapshot happy path: exact requests, echoes, digest, tombstone floors',
    () async {
      final f = Fake(), h = SeedSyncHttp(post: f.post);
      final c = await challenge(h, f);
      expect(f.sent.single.$1, '/v1/manage/seed-sync/snapshot-begin');
      expect(f.sent.single.$2, {'epoch': 4, 'keyId': keyId});
      expect(c.deviceId, 'dev');
      f.replies.add(
        ok(
          snapBody(
            entries: [entry('b', 8), entry('a', 5)],
            unsupported: [
              {'entryId': 'u', 'reason': 'metadata_pending'},
            ],
            tombstones: [
              {'entryId': 'x', 'revision': 3},
              {'entryId': 'x', 'revision': 7},
              {'entryId': 'a', 'revision': 4},
            ],
          ),
        ),
      );
      final s = await h.snapshotFinish(challenge: c, signature: sig);
      expect(f.sent.last.$1, '/v1/manage/seed-sync/snapshot-finish');
      expect(f.sent.last.$2, {'signature': sig, 'token': token});
      expect(s.revision, 9);
      expect(s.complete, isTrue);
      expect(s.entries.map((e) => e.entryId), ['b', 'a']);
      expect(s.unsupported, {'u': 'metadata_pending'});
      expect(s.tombstones, {'x': 7, 'a': 4});
      expect(s.maxBatch, 3);
    },
  );

  test(
    'snapshot-begin refuses a different key or epoch echo and bad shapes',
    () async {
      for (final bad in <Map<String, dynamic>>[
        snapChallenge(key: 'b' * 32),
        snapChallenge(epoch: 5),
        {...snapChallenge(), 'extra': 1},
        {'token': 'otpda_short', 'challenge': snapChallenge()['challenge']},
        {
          'token': token,
          'challenge': {
            ...(snapChallenge()['challenge'] as Map<String, dynamic>),
            'extra': 1,
          },
        },
      ]) {
        final f = Fake(), h = SeedSyncHttp(post: f.post);
        f.replies.add(ok(bad));
        await expectLater(
          h.snapshotBegin(keyId: keyId, epoch: 4),
          failsWith(SeedSyncPullFailure.shape),
        );
      }
    },
  );

  test(
    'snapshot-finish rejects anything that is not exactly the contract',
    () async {
      final cases = <String, Map<String, dynamic>>{
        'wrong owner': snapBody(over: {'ownerId': 'other'}),
        'wrong device': snapBody(over: {'deviceId': 'other'}),
        'wrong epoch': snapBody(over: {'epoch': 5}),
        'wrong digest': snapBody(over: {'challengeDigest': 'f' * 64}),
        'extra key': snapBody(over: {'extra': 1}),
        'complete not bool': snapBody(over: {'complete': 1}),
        'maxBatch 0': snapBody(over: {'maxBatch': 0}),
        'maxBatch 4': snapBody(over: {'maxBatch': 4}),
        'negative revision': snapBody(over: {'revision': -1}),
        'duplicate entry': snapBody(entries: [entry('a', 5), entry('a', 6)]),
        'bad algorithm': snapBody(
          entries: [
            {...entry('a', 5), 'algorithm': 'MD5'},
          ],
        ),
        'digits 5': snapBody(
          entries: [
            {...entry('a', 5), 'digits': 5},
          ],
        ),
        'period 0': snapBody(
          entries: [
            {...entry('a', 5), 'period': 0},
          ],
        ),
        'version 0': snapBody(entries: [entry('a', 0)]),
        'entry extra key': snapBody(
          entries: [
            {...entry('a', 5), 'x': 1},
          ],
        ),
        'unsupported overlaps entry': snapBody(
          unsupported: [
            {'entryId': 'a', 'reason': 'unsupported'},
          ],
        ),
        'unsupported bad reason': snapBody(
          unsupported: [
            {'entryId': 'u', 'reason': 'x'},
          ],
        ),
        'entry at or below tombstone': snapBody(
          tombstones: [
            {'entryId': 'a', 'revision': 5},
          ],
        ),
        'tombstone revision 0': snapBody(
          tombstones: [
            {'entryId': 'x', 'revision': 0},
          ],
        ),
        'too many tombstones': snapBody(
          tombstones: [
            for (var i = 0; i < 201; i++) {'entryId': 't$i', 'revision': 1},
          ],
        ),
        'over cap': snapBody(
          entries: [for (var i = 0; i < 1001; i++) entry('e$i', 1)],
        ),
      };
      for (final e in cases.entries) {
        final f = Fake(), h = SeedSyncHttp(post: f.post);
        final c = await challenge(h, f);
        f.replies.add(ok(e.value));
        await expectLater(
          h.snapshotFinish(challenge: c, signature: sig),
          failsWith(SeedSyncPullFailure.shape),
          reason: e.key,
        );
      }
    },
  );

  test(
    'definitive 409 codes are typed; every other failure is unavailable',
    () async {
      for (final (code, state) in [
        ('key-revoked', SeedSyncSignedState.keyRevoked),
        ('generation-changed', SeedSyncSignedState.generationChanged),
      ]) {
        final f = Fake(), h = SeedSyncHttp(post: f.post);
        final c = await challenge(h, f);
        f.replies.add((status: 409, body: {'error': code}));
        await expectLater(
          h.snapshotFinish(challenge: c, signature: sig),
          throwsA(
            isA<SeedSyncSignedStateException>().having(
              (e) => e.state,
              'state',
              state,
            ),
          ),
        );
      }
      final others = <R>[
        (status: 409, body: {'error': 'unavailable'}),
        (status: 409, body: {'error': 'key-revoked', 'x': 1}),
        (status: 409, body: null),
        (status: 401, body: {'error': 'key-revoked'}),
        (status: 429, body: {'error': 'rate_limited'}),
        (status: 503, body: {'error': 'unavailable'}),
        (status: 404, body: null),
      ];
      for (final r in others) {
        final f = Fake(), h = SeedSyncHttp(post: f.post);
        final c = await challenge(h, f);
        f.replies.add(r);
        await expectLater(
          h.snapshotFinish(challenge: c, signature: sig),
          failsWith(SeedSyncPullFailure.unavailable),
        );
      }
    },
  );

  test(
    'begin never surfaces the signed-state codes as a purge signal',
    () async {
      final f = Fake(), h = SeedSyncHttp(post: f.post);
      f.replies.add((status: 409, body: {'error': 'unavailable'}));
      await expectLater(
        h.snapshotBegin(keyId: keyId, epoch: 4),
        failsWith(SeedSyncPullFailure.unavailable),
      );
    },
  );

  test('argument shapes are refused before anything is sent', () async {
    final f = Fake(), h = SeedSyncHttp(post: f.post);
    expect(
      () => h.snapshotBegin(keyId: 'short', epoch: 1),
      throwsArgumentError,
    );
    expect(() => h.snapshotBegin(keyId: keyId, epoch: -1), throwsArgumentError);
    expect(
      () =>
          h.batchBegin(keyId: keyId, epoch: 1, ephemeralKey: eph, entries: []),
      throwsArgumentError,
    );
    expect(
      () => h.batchBegin(
        keyId: keyId,
        epoch: 1,
        ephemeralKey: 'x',
        entries: [(entryId: 'a', seedVersion: 1)],
      ),
      throwsArgumentError,
    );
    expect(
      () => h.batchBegin(
        keyId: keyId,
        epoch: 1,
        ephemeralKey: eph,
        entries: [
          for (final i in 'abcd'.split('')) (entryId: i, seedVersion: 1),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => h.batchBegin(
        keyId: keyId,
        epoch: 1,
        ephemeralKey: eph,
        entries: [
          (entryId: 'a', seedVersion: 1),
          (entryId: 'a', seedVersion: 1),
        ],
      ),
      throwsArgumentError,
    );
    expect(f.sent, isEmpty);
  });

  test(
    'batch-begin sends sorted-set digests the server must echo exactly',
    () async {
      final f = Fake(), h = SeedSyncHttp(post: f.post);
      final c = await batchChallenge(h, f);
      expect(f.sent.single.$1, '/v1/manage/seed-sync/batch-begin');
      expect(f.sent.single.$2, {
        'entries': [
          {'entryId': 'b', 'seedVersion': 2},
          {'entryId': 'a', 'seedVersion': 5},
        ],
        'ephemeralKey': eph,
        'epoch': 4,
        'keyId': keyId,
      });
      expect(
        c.entriesDigest,
        sha256HexOf(
          jsonEncode([
            ['a', 5],
            ['b', 2],
          ]),
        ),
      );
      for (final chOver in [
        {'entriesDigest': 'e' * 64},
        {'ephemeralDigest': 'e' * 64},
        {'keyId': 'b' * 32},
        {'epoch': 9},
      ]) {
        final f2 = Fake(), h2 = SeedSyncHttp(post: f2.post);
        await expectLater(
          batchChallenge(h2, f2, chOver: chOver),
          failsWith(SeedSyncPullFailure.shape),
        );
      }
      final f3 = Fake(), h3 = SeedSyncHttp(post: f3.post);
      await expectLater(
        batchChallenge(h3, f3, over: {'extra': 1}),
        failsWith(SeedSyncPullFailure.shape),
      );
    },
  );

  Map<String, dynamic> batchBody({
    List<Object?>? results,
    Object? spk,
    Map<String, Object?> over = const {},
  }) => {
    'ownerId': 'owner',
    'deviceId': 'dev',
    'epoch': 4,
    'challengeDigest': sha256HexOf(nonce),
    'serverPublicKey': spk ?? serverKey,
    'results':
        results ??
        [
          {
            'entryId': 'a',
            'status': 'sealed',
            'seedVersion': 5,
            'algorithm': 'SHA-1',
            'digits': 6,
            'period': 30,
            'nonce': nonce12,
            'ciphertext': ct,
          },
        ],
    ...over,
  };

  test('batch-finish happy path covers every status shape', () async {
    final f = Fake(), h = SeedSyncHttp(post: f.post);
    final c = await batchChallenge(h, f);
    f.replies.add(
      ok(
        batchBody(
          results: [
            {
              'entryId': 'a',
              'status': 'sealed',
              'seedVersion': 5,
              'algorithm': 'SHA-1',
              'digits': 6,
              'period': 30,
              'nonce': nonce12,
              'ciphertext': ct,
            },
            {'entryId': 'b', 'status': 'stale', 'seedVersion': 7},
            {'entryId': 'c', 'status': 'stale'},
          ],
        ),
      ),
    );
    final b = await h.batchFinish(challenge: c, signature: sig);
    expect(f.sent.last.$1, '/v1/manage/seed-sync/batch-finish');
    expect(b.serverPublicKey, serverKey);
    expect(b.results.map((r) => r.status.name), ['sealed', 'stale', 'stale']);
    expect(b.results[1].seedVersion, 7);
    expect(b.results[2].seedVersion, isNull);
    final f2 = Fake(), h2 = SeedSyncHttp(post: f2.post);
    final c2 = await batchChallenge(h2, f2);
    f2.replies.add(
      ok(
        batchBody(
          spk: null,
          results: [
            {'entryId': 'a', 'status': 'removed'},
            {'entryId': 'b', 'status': 'unsupported'},
          ],
          over: {'serverPublicKey': null},
        ),
      ),
    );
    final none = await h2.batchFinish(challenge: c2, signature: sig);
    expect(none.serverPublicKey, isNull);
    expect(none.results.map((r) => r.status.name), ['removed', 'unsupported']);
  });

  test(
    'batch-finish rejects anything that is not exactly the contract',
    () async {
      final sealed = {
        'entryId': 'a',
        'status': 'sealed',
        'seedVersion': 5,
        'algorithm': 'SHA-1',
        'digits': 6,
        'period': 30,
        'nonce': nonce12,
        'ciphertext': ct,
      };
      final cases = <String, Map<String, dynamic>>{
        'wrong owner': batchBody(over: {'ownerId': 'x'}),
        'wrong device': batchBody(over: {'deviceId': 'x'}),
        'wrong epoch': batchBody(over: {'epoch': 5}),
        'wrong digest': batchBody(over: {'challengeDigest': 'f' * 64}),
        'extra key': batchBody(over: {'extra': 1}),
        'sealed without server key': batchBody(over: {'serverPublicKey': null}),
        'server key without sealed': batchBody(
          results: [
            {'entryId': 'a', 'status': 'removed'},
          ],
        ),
        'non-point server key': batchBody(spk: 'A' * 87),
        'short nonce': batchBody(
          results: [
            {...sealed, 'nonce': 'AAAA'},
          ],
        ),
        'padded nonce': batchBody(
          results: [
            {...sealed, 'nonce': '$nonce12='},
          ],
        ),
        'non-canonical ciphertext': batchBody(
          results: [
            {...sealed, 'ciphertext': '${ct.substring(0, ct.length - 1)}B'},
          ],
        ),
        'oversized ciphertext': batchBody(
          results: [
            {
              ...sealed,
              'ciphertext': base64UrlEncode(List.filled(200, 1))
                  .replaceAll('=', ''),
            },
          ],
        ),
        'unknown status': batchBody(
          results: [
            {'entryId': 'a', 'status': 'ok'},
          ],
        ),
        'removed with extra': batchBody(
          results: [
            {'entryId': 'a', 'status': 'removed', 'seedVersion': 1},
          ],
        ),
        'duplicate entry': batchBody(
          results: [
            sealed,
            {...sealed},
          ],
        ),
        'sealed bad algorithm': batchBody(
          results: [
            {...sealed, 'algorithm': 'MD5'},
          ],
        ),
        'four results': batchBody(
          results: [
            for (final i in 'abcd'.split(''))
              {'entryId': i, 'status': 'removed'},
          ],
          spk: null,
          over: {'serverPublicKey': null},
        ),
        'results not a list': batchBody(over: {'results': {}}),
      };
      for (final e in cases.entries) {
        final f = Fake(), h = SeedSyncHttp(post: f.post);
        final c = await batchChallenge(h, f);
        f.replies.add(ok(e.value));
        await expectLater(
          h.batchFinish(challenge: c, signature: sig),
          failsWith(SeedSyncPullFailure.shape),
          reason: e.key,
        );
      }
    },
  );

  test(
    'batch-finish failures are unavailable or typed, never successes',
    () async {
      for (final r in <R>[
        (status: 409, body: {'error': 'unavailable'}),
        (status: 503, body: null),
        (status: 200, body: null),
      ]) {
        final f = Fake(), h = SeedSyncHttp(post: f.post);
        final c = await batchChallenge(h, f);
        f.replies.add(r);
        await expectLater(
          h.batchFinish(challenge: c, signature: sig),
          throwsA(anyOf(isA<SeedSyncPullException>())),
        );
      }
      final f = Fake(), h = SeedSyncHttp(post: f.post);
      final c = await batchChallenge(h, f);
      f.replies.add((status: 409, body: {'error': 'generation-changed'}));
      await expectLater(
        h.batchFinish(challenge: c, signature: sig),
        throwsA(isA<SeedSyncSignedStateException>()),
      );
    },
  );
}
