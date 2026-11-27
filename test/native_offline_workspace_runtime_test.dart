import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';
import 'package:otpanda_client/offline_totp/native_offline_workspace_runtime.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';
import 'package:otpanda_client/session_contract.dart';

import 'offline_totp/fake_seed_custody.dart';

void main() {
  late Directory dir;
  late FakeSecretStore keys;
  late FakeSeedCustody custody;
  late NativeOfflineWorkspaceRuntime runtime;
  var now = 59000;
  var unlocked = true;
  Future<void> open({bool fresh = false, String owner = 'owner'}) =>
      runtime.open(
        keys: keys,
        custody: custody,
        namespace: 'workspace',
        path: '${dir.path}/db',
        owner: owner,
        install: 'install',
        epoch: 0,
        admittedFreshWorkspace: fresh,
        stillLocallyUnlocked: () => unlocked,
      );
  NativeWorkspaceSnapshot saved() => NativeWorkspaceSnapshot(
    ownerId: 'owner',
    installId: 'install',
    epoch: 0,
    savedAtMs: 59000,
    entries: [
      const ManagedEntry('entry', 'Local service', 'me', true, true),
      const ManagedEntry('shared', 'Shared', 'them', false, true),
    ],
    codes: [
      ReceivedCode.fromJson({
        'entryId': 'entry',
        'code': 'stale1',
        'receivedAt': 59000,
        'expiresAt': 70000,
      }),
      ReceivedCode.fromJson({
        'entryId': 'shared',
        'code': '654321',
        'receivedAt': 59000,
        'expiresAt': 60000,
      }),
    ],
    sources: [],
    unassigned: [],
  );
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('local-runtime-');
    keys = FakeSecretStore();
    custody = FakeSeedCustody();
    now = 59000;
    unlocked = true;
    runtime = NativeOfflineWorkspaceRuntime(clock: () => now);
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
  tearDown(() {
    runtime.dispose();
    dir.deleteSync(recursive: true);
  });
  test(
    'cold open without any session restores encrypted metadata and local codes',
    () async {
      await open(fresh: true);
      runtime.publishAuthenticated(saved());
      runtime.lock();
      await open();
      expect(runtime.phase, NativeOfflineWorkspacePhase.ready);
      expect(runtime.snapshot!.entries.first.service, 'Local service');
      expect(
        runtime.visibleCodes.map((c) => c.value),
        containsAll(['94287082', '654321']),
      );
      now = 60000;
      await runtime.refreshLocalCodes();
      expect(runtime.visibleCodes.single.expiresAt, 90000);
    },
  );
  test(
    'repeated same-scope open keeps ciphertext snapshot and key unchanged',
    () async {
      await open(fresh: true);
      runtime.publishAuthenticated(saved());
      final before = File('${dir.path}/db').readAsBytesSync();
      for (var i = 0; i < 3; i++) {
        await open();
        expect(runtime.phase, NativeOfflineWorkspacePhase.ready);
        expect(runtime.snapshot!.ownerId, 'owner');
        expect(runtime.snapshot!.entries.first.service, 'Local service');
        expect(runtime.visibleCodes.map((c) => c.value), contains('94287082'));
      }
      expect(keys.creates, 1);
      expect(File('${dir.path}/db').readAsBytesSync(), before);
    },
  );
  test('locked custody never falls back to cached own TOTP code', () async {
    await open(fresh: true);
    runtime.publishAuthenticated(saved());
    custody.locked = true;
    await runtime.refreshLocalCodes();
    expect(runtime.visibleCodes.map((c) => c.entryId), ['shared']);
  });
  test('lock immediately hides metadata and codes and closes cache', () async {
    await open(fresh: true);
    runtime.publishAuthenticated(saved());
    await runtime.refreshLocalCodes();
    unlocked = false;
    expect(runtime.snapshot, isNull);
    expect(runtime.visibleCodes, isEmpty);
    expect(() => runtime.publishAuthenticated(saved()), throwsStateError);
    runtime.lock();
    expect(runtime.phase, NativeOfflineWorkspacePhase.locked);
  });
  test('wrong owner never resets healthy ciphertext', () async {
    await open(fresh: true);
    runtime.publishAuthenticated(saved());
    runtime.lock();
    final before = File('${dir.path}/db').readAsBytesSync();
    await open(owner: 'other');
    expect(runtime.phase, NativeOfflineWorkspacePhase.unavailable);
    expect(File('${dir.path}/db').readAsBytesSync(), before);
    expect(keys.creates, 1);
  });
  test('missing key on established workspace remains unavailable', () async {
    await open(fresh: true);
    runtime.publishAuthenticated(saved());
    runtime.lock();
    await keys.delete('workspace');
    await open();
    expect(runtime.phase, NativeOfflineWorkspacePhase.unavailable);
    expect(keys.creates, 1);
  });
}
