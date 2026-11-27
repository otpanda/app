import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/native_workspace_unlock.dart';
import 'package:otpanda_client/offline_totp/encrypted_workspace_database.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';

class HeldKeys implements SecretStore {
  final inner = FakeSecretStore();
  @override
  String get kind => inner.kind;
  int get creates => inner.creates;
  int get deletes => inner.deletes;
  set failAll(SecretStoreError? value) => inner.failAll = value;
  @override
  Future<Uint8List> createIfAbsent(String name, Uint8List candidate) =>
      inner.createIfAbsent(name, candidate);
  @override
  Future<void> delete(String name) => inner.delete(name);
  void Function()? afterRead;
  @override
  Future<Uint8List?> read(String name) async {
    final result = await inner.read(name);
    afterRead?.call();
    return result;
  }
}

void main() {
  late Directory dir;
  late String path;
  late HeldKeys keys;
  bool unlocked = true;
  Future<NativeWorkspaceUnlockSession> open({
    bool fresh = false,
    String owner = 'owner',
  }) => NativeWorkspaceUnlockSession.open(
    keys: keys,
    namespace: 'workspace',
    path: path,
    owner: owner,
    install: 'install',
    epoch: 1,
    admittedFreshWorkspace: fresh,
    stillUnlocked: () => unlocked,
  );
  setUp(() {
    dir = Directory.systemTemp.createTempSync('workspace-unlock-');
    path = '${dir.path}/cache';
    keys = HeldKeys();
    unlocked = true;
  });
  tearDown(() => dir.deleteSync(recursive: true));
  test(
    'explicit fresh admission creates encrypted state and restart reopens',
    () async {
      final first = await open(fresh: true);
      first.database.transaction(
        () => first.database.put('settings', 'value', {
          'label': 'private-marker',
        }),
      );
      first.close();
      final next = await open();
      expect(
        next.database.read('settings', 'value')?['label'],
        'private-marker',
      );
      next.close();
      expect(keys.creates, 1);
      expect(
        String.fromCharCodes(File(path).readAsBytesSync()),
        isNot(contains('private-marker')),
      );
    },
  );
  test('absence is not fresh admission and never creates a key', () async {
    await expectLater(open(), throwsA(isA<WorkspaceDatabaseException>()));
    expect(keys.creates, 0);
    expect(File(path).existsSync(), false);
  });
  test(
    'missing key with existing ciphertext preserves file even with admission',
    () async {
      final first = await open(fresh: true);
      first.close();
      final before = File(path).readAsBytesSync();
      await keys.delete('workspace');
      await expectLater(
        open(fresh: true),
        throwsA(isA<WorkspaceDatabaseException>()),
      );
      expect(keys.creates, 1);
      expect(File(path).readAsBytesSync(), before);
    },
  );
  test('owner mismatch refuses without changing ciphertext or key', () async {
    final first = await open(fresh: true);
    first.close();
    final before = File(path).readAsBytesSync();
    await expectLater(
      open(owner: 'other'),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
    expect(File(path).readAsBytesSync(), before);
    expect(keys.creates, 1);
    expect(keys.deletes, 0);
  });
  test(
    'lock during async key read fences database opening and creation',
    () async {
      keys.afterRead = () => unlocked = false;
      await expectLater(open(fresh: true), throwsStateError);
      expect(keys.creates, 0);
      expect(File(path).existsSync(), false);
    },
  );
  test('OS lock or corrupt key never becomes missing or fresh reset', () async {
    for (final error in [
      SecretStoreError.locked,
      SecretStoreError.corrupt,
      SecretStoreError.denied,
    ]) {
      keys.failAll = error;
      await expectLater(
        open(fresh: true),
        throwsA(isA<SecretStoreException>()),
      );
    }
    expect(keys.creates, 0);
    expect(File(path).existsSync(), false);
  });
}
