import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/session_contract.dart';

class FakeTransport implements SessionTransport {
  final Future<SessionResponse> Function(String) handler;
  FakeTransport(this.handler);
  @override
  Future<SessionResponse> getManagement(String path) => handler(path);
  @override
  Future<void> close() async {}
}

SessionResponse ok(Object value) => SessionResponse(200, jsonEncode(value));
Map<String, Object> entry(String id) => {
  'entry_id': id,
  'service_name': 'Northstar',
  'account_name': 'fictional',
  'capabilities': {'manage': false},
};
Map<String, Object> code(String id, {int received = 100, int expires = 200}) =>
    {
      'entryId': id,
      'code': 'A12-34',
      'receivedAt': received,
      'expiresAt': expires,
    };
void main() {
  test('private inbox only includes live owner source records, retains empty entries and redacts', () async {
    final store = CodeStore(
      FakeTransport((path) async {
        if (path.endsWith('/session')) {
          return ok({'ownerId': 'owner', 'expiresAt': 999});
        }
        if (path.endsWith('/entries')) {
          return ok({
            'entries': [entry('empty')],
          });
        }
        if (path.endsWith('/sources')) {
          return ok({
            'sources': [
              {
                'source_id': 'mine',
                'kind': 'sms',
                'label': 'Phone',
                'revoked_at': null,
              },
              {
                'source_id': 'revoked',
                'kind': 'gmail',
                'label': 'Old mailbox',
                'revoked_at': 1,
              },
            ],
          });
        }
        if (path.endsWith('/unassigned')) {
          return ok({
            'records': [
              {
                'sourceId': 'mine',
                'eventId': 'one',
                'code': '123456',
                'receivedAt': 100,
                'expiresAt': 200,
              },
              {
                'sourceId': 'other',
                'eventId': 'two',
                'code': '999999',
                'receivedAt': 100,
                'expiresAt': 200,
              },
              {
                'sourceId': 'revoked',
                'eventId': 'three',
                'code': '333333',
                'receivedAt': 100,
                'expiresAt': 200,
              },
            ],
          });
        }
        return ok({'records': []});
      }),
    );
    await store.load(() => 150, includePrivateInbox: true);
    expect(store.entries.single.id, 'empty');
    expect(store.sources.single.label, 'Phone');
    expect(store.visibleUnassigned(150).single.value, '123456');
    expect(store.visibleUnassigned(200), isEmpty);
    expect(
      store.visibleUnassigned(150).single.toString(),
      isNot(contains('123456')),
    );
    store.clear();
    expect(store.sources, isEmpty);
    expect(store.visibleUnassigned(150), isEmpty);
  });
  test('clear during private inbox request prevents late source or code publication', () async {
    final pending = Completer<SessionResponse>();
    final store = CodeStore(
      FakeTransport((p) async {
        if (p.endsWith('/session')) {
          return ok({'ownerId': 'owner', 'expiresAt': 999});
        }
        if (p.endsWith('/entries')) return ok({'entries': []});
        if (p.endsWith('/sources')) return pending.future;
        return ok({'records': []});
      }),
    );
    final load = store.load(() => 150, includePrivateInbox: true);
    await Future<void>.delayed(Duration.zero);
    store.clear();
    pending.complete(
      ok({
        'sources': [
          {
            'source_id': 'mine',
            'kind': 'sms',
            'label': 'Phone',
            'revoked_at': null,
          },
        ],
      }),
    );
    await load;
    expect(store.sources, isEmpty);
    expect(store.entries, isEmpty);
  });
  test('private endpoint denial clears the complete snapshot', () async {
    final store = CodeStore(
      FakeTransport((p) async {
        if (p.endsWith('/session')) {
          return ok({'ownerId': 'owner', 'expiresAt': 999});
        }
        if (p.endsWith('/entries')) {
          return ok({
            'entries': [entry('a')],
          });
        }
        if (p.endsWith('/sources')) return const SessionResponse(401, '{}');
        return ok({'records': []});
      }),
    );
    await expectLater(
      store.load(() => 150, includePrivateInbox: true),
      throwsA(isA<ClientFailure>()),
    );
    expect(store.entries, isEmpty);
    expect(store.sources, isEmpty);
  });

  test(
    'only current codes for visible entries, explicit capabilities, redaction',
    () async {
      final store = CodeStore(
        FakeTransport((path) async {
          if (path.endsWith('/session')) {
            return ok({'ownerId': 'owner', 'expiresAt': 999});
          }
          if (path.endsWith('/entries')) {
            return ok({
              'entries': [entry('a')],
            });
          }
          return ok({
            'records': [
              code('a'),
              code('hidden'),
              code('a', expires: 140),
              code('a', received: 160),
            ],
          });
        }),
      );
      await store.load(() => 150);
      expect(store.entries.single.manage, false);
      expect(store.visibleCodes(150).length, 1);
      expect(store.visibleCodes(200), isEmpty);
      expect(
        store.visibleCodes(150).single.toString(),
        isNot(contains('A12-34')),
      );
      store.clear();
      expect(store.entries, isEmpty);
      expect(store.visibleCodes(150), isEmpty);
    },
  );
  test('late responses cannot restore data after clear', () async {
    final pending = Completer<SessionResponse>();
    final store = CodeStore(
      FakeTransport((path) async {
        if (path.endsWith('/session')) {
          return ok({'ownerId': 'owner', 'expiresAt': 999});
        }
        return pending.future;
      }),
    );
    final load = store.load(() => 150);
    await Future<void>.delayed(Duration.zero);
    store.clear();
    pending.complete(
      ok({
        'entries': [entry('a')],
      }),
    );
    await load;
    expect(store.entries, isEmpty);
  });
  test(
    '401 clears state and is distinguishable without response disclosure',
    () async {
      final store = CodeStore(
        FakeTransport(
          (_) async => const SessionResponse(401, 'private response'),
        ),
      );
      await expectLater(
        store.load(() => 150),
        throwsA(
          isA<ClientFailure>().having((e) => e.signedOut, 'signed out', true),
        ),
      );
      expect(store.entries, isEmpty);
    },
  );
  test(
    'malformed response fails closed without leaking its contents',
    () async {
      final store = CodeStore(
        FakeTransport((path) async {
          if (path.endsWith('/session')) {
            return ok({'ownerId': 'owner', 'expiresAt': 999});
          }
          return ok({
            'entries': [
              {'entry_id': 'secret-value'},
            ],
          });
        }),
      );
      await expectLater(
        store.load(() => 150),
        throwsA(
          isA<ClientFailure>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('secret-value')),
          ),
        ),
      );
      expect(store.entries, isEmpty);
    },
  );
  test(
    'failed refresh drops previous data rather than retaining stale codes',
    () async {
      var failed = false;
      final store = CodeStore(
        FakeTransport((path) async {
          if (failed) return const SessionResponse(503, '');
          if (path.endsWith('/session')) {
            return ok({'ownerId': 'owner', 'expiresAt': 999});
          }
          if (path.endsWith('/entries')) {
            return ok({
              'entries': [entry('a')],
            });
          }
          return ok({
            'records': [code('a')],
          });
        }),
      );
      await store.load(() => 150);
      expect(store.visibleCodes(150), isNotEmpty);
      failed = true;
      await expectLater(store.load(() => 150), throwsA(isA<ClientFailure>()));
      expect(store.entries, isEmpty);
      expect(store.visibleCodes(150), isEmpty);
    },
  );
}
