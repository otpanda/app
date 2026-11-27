import 'encrypted_workspace_database.dart';
import 'native_workspace_snapshot.dart';

/// Typed bridge between last-known UI data and the encrypted transaction.
/// Does not own session auth, key creation, epochs or NativeSeedCustody.
final class NativeWorkspaceCache {
  NativeWorkspaceCache(this.database);
  final EncryptedWorkspaceDatabase database;
  void save(NativeWorkspaceSnapshot snapshot) {
    if (snapshot.ownerId != database.owner ||
        snapshot.installId != database.install ||
        snapshot.epoch != database.epoch) {
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.scopeMismatch,
      );
    }
    database.transaction(
      () => database.put('snapshot', 'ui', snapshot.toJson()),
    );
  }

  NativeWorkspaceSnapshot? read() {
    final value = database.read('snapshot', 'ui');
    if (value == null) return null;
    final snapshot = NativeWorkspaceSnapshot.fromJson(value);
    if (snapshot.ownerId != database.owner ||
        snapshot.installId != database.install ||
        snapshot.epoch != database.epoch) {
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.scopeMismatch,
      );
    }
    return snapshot;
  }

  @override
  String toString() => 'NativeWorkspaceCache(redacted)';
}
