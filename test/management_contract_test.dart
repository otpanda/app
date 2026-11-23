import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/management_contract.dart';
import 'package:otpanda_client/session_contract.dart';

class FakeManagement implements ManagementTransport {
  final Future<SessionResponse> Function(String, String, Map<String, Object?>?)
  handle;
  FakeManagement(this.handle);
  @override
  Future<SessionResponse> request(
    String path,
    String method,
    Map<String, Object?>? body,
  ) => handle(path, method, body);
}

void main() {
  test(
    'create sends entry contract not account owner or service-scoped grant',
    () async {
      final client = ManagementClient(
        FakeManagement((path, method, body) async {
          expect(path, '/v1/manage/entries');
          expect(method, 'POST');
          expect(body, {
            'serviceId': 'example.test',
            'label': 'Personal',
            'accountName': 'user',
          });
          return const SessionResponse(201, '{"entryId":"new"}');
        }),
      );
      expect(
        await client.createEntry(
          serviceId: ' example.test ',
          label: 'Personal',
          account: 'user',
        ),
        'new',
      );
    },
  );
  test('invalid input is rejected before transport', () async {
    var calls = 0;
    final client = ManagementClient(
      FakeManagement((_, _, _) async {
        calls++;
        return const SessionResponse(200, '{"ok":true}');
      }),
    );
    expect(() => client.deleteEntry(' '), throwsArgumentError);
    expect(() => client.revokeToken('bad/path'), throwsArgumentError);
    expect(calls, 0);
  });
  test(
    'ambiguous mutation never auto retries or exposes diagnostics',
    () async {
      var calls = 0;
      final client = ManagementClient(
        FakeManagement((_, _, _) async {
          calls++;
          throw StateError('private diagnostics');
        }),
      );
      await expectLater(
        client.deleteEntry('entry'),
        throwsA(
          isA<MutationUnconfirmed>().having(
            (e) => e.toString(),
            'safe message',
            isNot(contains('private diagnostics')),
          ),
        ),
      );
      expect(calls, 1);
    },
  );
  test(
    'malformed success and server failure are uncertain,401 distinct',
    () async {
      for (final response in [
        const SessionResponse(200, '{}'),
        const SessionResponse(503, 'internal'),
      ]) {
        final client = ManagementClient(
          FakeManagement((_, _, _) async => response),
        );
        await expectLater(
          client.revokeSource('phone'),
          throwsA(isA<MutationUnconfirmed>()),
        );
      }
      final client = ManagementClient(
        FakeManagement(
          (_, _, _) async => const SessionResponse(401, 'internal'),
        ),
      );
      await expectLater(
        client.deleteEntry('entry'),
        throwsA(
          isA<ClientFailure>().having((e) => e.signedOut, 'signed out', true),
        ),
      );
    },
  );
  test('assignment and clear-account preserve exact scoped request', () async {
    final sent = <Object>[];
    final client = ManagementClient(
      FakeManagement((path, method, body) async {
        sent.add([path, method, body]);
        return const SessionResponse(200, '{"ok":true}');
      }),
    );
    await client.assignCode(
      sourceId: 'phone',
      eventId: 'event',
      entryId: 'entry',
    );
    await client.updateAccount('entry', ' ');
    expect(sent, [
      [
        '/v1/manage/confirm-assignment',
        'POST',
        {'sourceId': 'phone', 'eventId': 'event', 'entryId': 'entry'},
      ],
      [
        '/v1/manage/entry-account',
        'PATCH',
        {'entryId': 'entry', 'accountName': null},
      ],
    ]);
  });
}
