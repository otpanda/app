import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/management_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/sharing_contract.dart';

class RuntimeTransport implements ManagementTransport {
  RuntimeTransport(this.process, this.lines, this.actor);
  final Process process;
  final StreamIterator<String> lines;
  final String actor;
  @override
  Future<SessionResponse> request(
    String path,
    String method,
    Map<String, Object?>? body,
  ) async {
    if (method != 'POST') throw StateError('POST only');
    process.stdin.writeln(
      jsonEncode({'actor': actor, 'path': path, 'body': body}),
    );
    if (!await lines.moveNext()) throw StateError('Runtime ended');
    final r = jsonDecode(lines.current) as Map<String, dynamic>;
    return SessionResponse(r['status'] as int, r['body'] as String);
  }
}

void main() {
  test(
    'actual Dart sharing client talks to opt-in identity runtime with SQLite',
    () async {
      final fixture = Platform.environment['SHARING_RUNTIME_FIXTURE'];
      if (fixture == null) return;
      final process = await Process.start('node', [fixture]);
      final errors = <String>[];
      process.stderr.transform(utf8.decoder).listen(errors.add);
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        final owner = SharingClient(RuntimeTransport(process, lines, 'owner'));
        final recipient = SharingClient(
          RuntimeTransport(process, lines, 'recipient'),
        );
        // Deliberately discard the one-time response, recover only pending metadata.
        await owner.createInvite(
          mode: AccessMode.all,
          entryIds: [],
          canDelegate: false,
          ttlSeconds: 3600,
        );
        final lost = (await owner.listInvites()).single;
        await expectLater(
          recipient.revokeInvite(lost.inviteId),
          throwsA(isA<ClientFailure>()),
        );
        await owner.revokeInvite(lost.inviteId);
        expect(await owner.listInvites(), isEmpty);
        final invite = await owner.createInvite(
          mode: AccessMode.all,
          entryIds: [],
          canDelegate: false,
          ttlSeconds: 3600,
        );
        final pending = await owner.listInvites();
        expect(pending, hasLength(1));
        expect(pending.single.inviteId, invite.inviteId);
        expect(await recipient.listInvites(), isEmpty);
        final accepted = await recipient.acceptInvite(invite.token);
        expect(accepted.mode, AccessMode.all);
        expect(accepted.canDelegate, false);
        final contacts = await owner.listContacts();
        expect(contacts, hasLength(1));
        expect(contacts.single.email, 'recipient@example.test');
        expect(contacts.single.grant?.mode, AccessMode.all);
        await owner.revokeGrant(contacts.single.contactRef);
        expect((await owner.listContacts()).single.grant, isNull);
        await expectLater(
          recipient.acceptInvite(invite.token),
          throwsA(isA<ClientFailure>()),
        );
      } finally {
        await process.stdin.close();
        expect(await process.exitCode, 0, reason: errors.join());
        await lines.cancel();
      }
    },
    skip: Platform.environment['SHARING_RUNTIME_FIXTURE'] == null
        ? 'Opt-in local runtime fixture not supplied'
        : false,
  );
}
