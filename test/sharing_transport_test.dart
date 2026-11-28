import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/sharing_transport.dart';
import 'package:otpanda_client/session_contract.dart';

void main() {
  test('retired sharing transport never sends or replays', () async {
    var live = false, calls = 0;
    final t = BoundSharingTransport(
      current: () async => live,
      send: (p, b) async {
        calls++;
        return const SessionResponse(200, '{}');
      },
    );
    expect(
      (await t.request('/v1/manage/sharing/contacts/list', 'POST', {})).status,
      503,
    );
    expect(calls, 0);
    live = true;
    expect(
      (await t.request('/v1/manage/sharing/contacts/list', 'POST', {})).status,
      200,
    );
    expect(calls, 1);
    await expectLater(
      t.request('/v1/machine/code', 'POST', {}),
      throwsStateError,
    );
    expect(calls, 1);
    await expectLater(
      t.request('/v1/manage/sharing/invite/accept', 'POST', {
        'token': 'A' * 32,
      }),
      throwsStateError,
    );
  });
  test('identity change during request drops response without retry', () async {
    var live = true, calls = 0;
    final gate = Completer<SessionResponse>();
    final t = BoundSharingTransport(
      current: () async => live,
      send: (p, b) {
        calls++;
        return gate.future;
      },
    );
    final result = t.request('/v1/manage/sharing/invite/create', 'POST', {});
    await Future<void>.delayed(Duration.zero);
    live = false;
    gate.complete(const SessionResponse(200, '{"token":"synthetic"}'));
    expect((await result).status, 503);
    expect(calls, 1);
  });
}
