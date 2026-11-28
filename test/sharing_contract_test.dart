import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/management_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/sharing_contract.dart';

class Fake implements ManagementTransport {
  final Future<SessionResponse> Function(String, String, Map<String, Object?>?)
  handle;
  Fake(this.handle);
  @override
  Future<SessionResponse> request(
    String p,
    String m,
    Map<String, Object?>? b,
  ) => handle(p, m, b);
}

void main() {
  test('invite create sends strict body and the link keeps the token in the fragment', () async {
    final c = SharingClient(
      Fake((p, m, b) async {
        expect(p, '/v1/manage/sharing/invite/create');
        expect(m, 'POST');
        expect(b, {
          'mode': 'deny',
          'entryIds': ['e3'],
          'canDelegate': true,
          'ttlSeconds': 3600,
        });
        return const SessionResponse(
          200,
          '{"token":"tok_abc","inviteId":"i1","expiresAt":5}',
        );
      }),
    );
    final r = await c.createInvite(
      mode: AccessMode.deny,
      entryIds: ['e3'],
      canDelegate: true,
      ttlSeconds: 3600,
    );
    expect(r.link().fragment, '/invite/tok_abc');
    expect(r.link().query, isEmpty);
    expect(r.toString(), isNot(contains('tok_abc')));
  });

  test('invalid entry lists are rejected before any request', () {
    final c = SharingClient(
      Fake((p, m, b) async => fail('no request expected')),
    );
    expect(
      () => c.createProfile(name: 'ci', mode: AccessMode.all, entryIds: ['e1']),
      throwsArgumentError,
    );
    expect(
      () => c.createProfile(name: 'ci', mode: AccessMode.allow, entryIds: []),
      throwsArgumentError,
    );
    expect(() => c.revokeGrant('a/b'), throwsArgumentError);
  });

  test(
    'failures map to ClientFailure and unconfirmed outcomes never retry',
    () async {
      var calls = 0;
      final c = SharingClient(
        Fake((p, m, b) async {
          calls++;
          return calls == 1
              ? const SessionResponse(404, '{}')
              : const SessionResponse(500, '');
        }),
      );
      await expectLater(c.revokeProfile('p1'), throwsA(isA<ClientFailure>()));
      await expectLater(
        c.revokeProfile('p1'),
        throwsA(isA<MutationUnconfirmed>()),
      );
      expect(calls, 2);
    },
  );

  test(
    'machine token response parses and hides the token in toString',
    () async {
      final c = SharingClient(
        Fake((p, m, b) async {
          expect(b, {'profileId': 'p1', 'ttlSeconds': 600});
          return const SessionResponse(
            200,
            '{"token":"mt_secret","tokenId":"t1","expiresAt":9}',
          );
        }),
      );
      final t = await c.createMachineToken(
        'p1',
        ttl: const Duration(seconds: 600),
      );
      expect(t.token, 'mt_secret');
      expect(t.toString(), isNot(contains('mt_secret')));
    },
  );

  test('token lifetime defaults to one year, allows custom or never, rejects ambiguity', () async {
    Map<String, Object?>? seen;
    final c = SharingClient(
      Fake((p, m, b) async {
        seen = b;
        return const SessionResponse(
          200,
          '{"token":"t","tokenId":"i","expiresAt":null}',
        );
      }),
    );
    await c.createMachineToken('p1');
    expect(seen!['ttlSeconds'], 365 * 86400);
    final n = await c.createMachineToken('p1', neverExpires: true);
    expect(seen!.containsKey('ttlSeconds'), isTrue);
    expect(seen!['ttlSeconds'], isNull);
    expect(n.expiresAt, isNull);
    expect(
      () => c.createMachineToken('p1', ttl: const Duration(days: 3651)),
      throwsArgumentError,
    );
    expect(
      () => c.createMachineToken(
        'p1',
        ttl: const Duration(days: 5),
        neverExpires: true,
      ),
      throwsArgumentError,
    );
  });

  test('contacts use opaque refs, parse grant state, and check the picture host', () async {
    final ref = 'a' * 32;
    final c = SharingClient(
      Fake((p, m, b) async {
        if (p.endsWith('contacts/list')) {
          expect(b, isEmpty);
          return SessionResponse(
            200,
            '{"contacts":[{"contactRef":"$ref","since":3,"hidden":false,"name":"Rec I","email":"a@b.test","picture":"https://lh3.googleusercontent.com/a/x","grant":{"mode":"deny","canDelegate":true}},{"contactRef":"${'b' * 32}","since":4,"hidden":true,"name":null,"email":null,"grant":null}]}',
          );
        }
        expect(p, '/v1/manage/sharing/grant/create');
        expect(b, {
          'contactRef': ref,
          'mode': 'all',
          'entryIds': <String>[],
          'canDelegate': false,
        });
        return const SessionResponse(200, '{"ok":true}');
      }),
    );
    final list = await c.listContacts();
    expect(list[0].name, 'Rec I');
    expect(list[0].email, 'a@b.test');
    expect(list[0].picture, isNotNull);
    expect(list[0].grant!.mode, AccessMode.deny);
    expect(list[0].grant!.canDelegate, isTrue);
    expect(list[1].hidden, isTrue);
    expect(list[1].grant, isNull);
    await c.createGrantForContact(
      contactRef: ref,
      mode: AccessMode.all,
      entryIds: [],
      canDelegate: false,
    );
    expect(() => c.revokeGrant('rec'), throwsArgumentError);
  });

  test('profile list parses metadata only and token revoke is distinct from profile revoke', () async {
    final seen = <String>[];
    final c = SharingClient(
      Fake((p, m, b) async {
        seen.add(p);
        if (p.endsWith('profiles/list')) {
          return const SessionResponse(
            200,
            '{"profiles":[{"profileId":"p1","name":"ci","mode":"deny","createdAt":1,"revokedAt":null,"entryIds":["e1"],"tokens":[{"tokenId":"t1","createdAt":2,"expiresAt":null,"revokedAt":null},{"tokenId":"t2","createdAt":3,"expiresAt":10,"revokedAt":null},{"tokenId":"t3","createdAt":4,"expiresAt":null,"revokedAt":5}]}]}',
          );
        }
        if (p.endsWith('entries/list')) {
          return const SessionResponse(
            200,
            '{"entries":[{"entryId":"e1","label":"Mozilla","account":"me","owned":true},{"entryId":"e9","label":"Shared","account":"","owned":false}]}',
          );
        }
        if (p.endsWith('token/revoke')) {
          expect(b, {'profileId': 'p1', 'tokenId': 't1'});
        }
        return const SessionResponse(200, '{"ok":true}');
      }),
    );
    final ps = await c.listProfiles();
    expect(ps.single.mode, AccessMode.deny);
    expect(
      ps.single.tokens[0].activeAt(1 << 40),
      isTrue,
      reason: 'never expires',
    );
    expect(ps.single.tokens[1].activeAt(11), isFalse, reason: 'expired');
    expect(ps.single.tokens[2].activeAt(0), isFalse, reason: 'revoked');
    final es = await c.listMachineEntries();
    expect(es.map((e) => e.owned), [true, false]);
    await c.revokeToken('p1', 't1');
    await c.revokeProfile('p1');
    expect(seen.where((s) => s.endsWith('token/revoke')).length, 1);
    expect(seen.where((s) => s.endsWith('profile/revoke')).length, 1);
  });
}
