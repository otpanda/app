import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';
import 'package:otpanda_client/offline_totp/native_workspace_code_reader.dart';
import 'package:otpanda_client/session_contract.dart';

import 'offline_totp/fake_seed_custody.dart';

void main() {
  late FakeSeedCustody custody;
  late NativeWorkspaceCodeReader reader;
  var now = 59000;
  var unlocked = true;
  const entries = [ManagedEntry('entry', 'Example', 'user', true, true)];
  setUp(() async {
    custody = FakeSeedCustody();
    now = 59000;
    unlocked = true;
    reader = NativeWorkspaceCodeReader(
      custody: custody,
      owner: 'owner',
      epoch: 0,
      stillUnlocked: () => unlocked,
      clock: () => now,
    );
    await custody.provision(
      ownerId: 'owner',
      entryId: 'entry',
      seedVersion: 1,
      algorithm: OtpAlgorithm.sha1,
      digits: 8,
      period: 30,
      seed: Uint8List.fromList('12345678901234567890'.codeUnits),
      epoch: 0,
    );
  });
  test('RFC code uses period boundary, not time of read', () async {
    final codes = await reader.read(entries);
    expect(codes.single.value, '94287082');
    expect(codes.single.receivedAt, 30000);
    expect(codes.single.expiresAt, 60000);
    expect(codes.single.active(60000), false);
  });
  test('only visible TOTP entries can generate', () async {
    expect(await reader.read([]), isEmpty);
    expect(
      await reader.read([const ManagedEntry('entry', 'E', 'A', true)]),
      isEmpty,
    );
  });
  test('unlock lifetime and close stop access', () async {
    unlocked = false;
    expect(await reader.read(entries), isEmpty);
    unlocked = true;
    reader.close();
    expect(await reader.read(entries), isEmpty);
  });
  test('locked, corrupt, deleted and disabled never reuse last code', () async {
    expect(await reader.read(entries), hasLength(1));
    custody.locked = true;
    expect(await reader.read(entries), isEmpty);
    custody.locked = false;
    custody.corrupt('owner', 'entry');
    expect(await reader.read(entries), isEmpty);
    await custody.delete('owner', 'entry', seedVersion: 1);
    expect(await reader.read(entries), isEmpty);
    await custody.clearOwner('owner', epoch: 0);
    expect(await reader.read(entries), isEmpty);
  });
  test('clock rollback refuses until prior time recovered', () async {
    expect(await reader.read(entries), hasLength(1));
    now = 58000;
    expect(await reader.read(entries), isEmpty);
    now = 60000;
    final next = await reader.read(entries);
    expect(next.single.expiresAt, 90000);
  });
  test('wrong epoch refuses catalog', () async {
    final wrong = NativeWorkspaceCodeReader(
      custody: custody,
      owner: 'owner',
      epoch: 1,
      stillUnlocked: () => true,
      clock: () => now,
    );
    expect(await wrong.read(entries), isEmpty);
  });
  for (final action in ['lock', 'delete', 'expire', 'rollback', 'new-read']) {
    test('in-flight code fenced after $action', () async {
      final slow = FakeSeedCustody();
      final started = Completer<void>();
      final release = Completer<void>();
      var pause = true;
      slow.afterGenerate = () async {
        if (pause) {
          pause = false;
          started.complete();
          await release.future;
        }
      };
      await slow.provision(
        ownerId: 'owner',
        entryId: 'entry',
        seedVersion: 1,
        algorithm: OtpAlgorithm.sha1,
        digits: 8,
        period: 30,
        seed: Uint8List.fromList('12345678901234567890'.codeUnits),
        epoch: 0,
      );
      final pendingReader = NativeWorkspaceCodeReader(
        custody: slow,
        owner: 'owner',
        epoch: 0,
        stillUnlocked: () => unlocked,
        clock: () => now,
      );
      final pending = pendingReader.read(entries);
      await started.future;
      switch (action) {
        case 'lock':
          unlocked = false;
        case 'delete':
          await slow.delete('owner', 'entry', seedVersion: 1);
        case 'expire':
          now = 60000;
        case 'rollback':
          now = 58000;
        case 'new-read':
          expect(await pendingReader.read(entries), hasLength(1));
      }
      release.complete();
      expect(await pending, isEmpty);
    });
  }
  test('result never carries seed diagnostics', () {
    expect(reader.toString(), 'NativeWorkspaceCodeReader(redacted)');
  });
}
