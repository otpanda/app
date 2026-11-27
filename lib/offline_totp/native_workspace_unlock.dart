import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'encrypted_workspace_database.dart';
import 'native_workspace_cache.dart';
import 'secret_store.dart';

/// Open only after native local-unlock admission of owner/install/epoch.
/// This does not infer a fresh install from missing files or missing keys.
/// The caller must establish create permission from durable installation state.
final class NativeWorkspaceUnlockSession {
  NativeWorkspaceUnlockSession._(this.database);
  final EncryptedWorkspaceDatabase database;
  NativeWorkspaceCache get cache => NativeWorkspaceCache(database);

  static Future<NativeWorkspaceUnlockSession> open({
    required SecretStore keys,
    required String namespace,
    required String path,
    required String owner,
    required String install,
    required int epoch,
    required bool admittedFreshWorkspace,
    required bool Function() stillUnlocked,
  }) async {
    void fence() {
      if (!stillUnlocked()) throw StateError('Workspace unlock ended');
    }

    fence();
    Uint8List? key = await keys.read(namespace);
    try {
      fence();
      if (key == null) {
        if (!admittedFreshWorkspace || File(path).existsSync()) {
          throw const WorkspaceDatabaseException(
            WorkspaceDatabaseError.missing,
          );
        }
        final random = Random.secure();
        final candidate = Uint8List.fromList(
          List.generate(32, (_) => random.nextInt(256)),
        );
        try {
          key = await keys.createIfAbsent(namespace, candidate);
        } finally {
          candidate.fillRange(0, candidate.length, 0);
        }
        fence();
      }
      final db = EncryptedWorkspaceDatabase.open(
        path: path,
        key: key,
        owner: owner,
        install: install,
        epoch: epoch,
        allowCreate: admittedFreshWorkspace,
      );
      try {
        fence();
        return NativeWorkspaceUnlockSession._(db);
      } catch (_) {
        db.close();
        rethrow;
      }
    } finally {
      key?.fillRange(0, key.length, 0);
    }
  }

  void close() => database.close();
  @override
  String toString() => 'NativeWorkspaceUnlockSession(redacted)';
}
