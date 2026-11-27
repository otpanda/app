import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

enum WorkspaceDatabaseError {
  unavailable,
  lockedOrCorrupt,
  scopeMismatch,
  missing,
}

final class WorkspaceDatabaseException implements Exception {
  const WorkspaceDatabaseException(this.error);
  final WorkspaceDatabaseError error;
  @override
  String toString() => 'WorkspaceDatabaseException(${error.name})';
}

/// SQLCipher transaction boundary for native cached UI and durable edit state.
/// No key generation, key replacement, reset, network or custody authorization.
/// Caller must admit the durable install/owner/epoch before [open]. Seeds remain
/// in NativeSeedCustody, never this cache. All SQLite failures preserve the file.
final class EncryptedWorkspaceDatabase {
  EncryptedWorkspaceDatabase._(this._db, this.owner, this.install, this.epoch);
  final Database _db;
  final String owner, install;
  final int epoch;
  bool _closed = false;
  bool _inTransaction = false;

  static EncryptedWorkspaceDatabase open({
    required String path,
    required Uint8List key,
    required String owner,
    required String install,
    required int epoch,
    required bool allowCreate,
  }) {
    if (key.length != 32 ||
        owner.isEmpty ||
        install.isEmpty ||
        epoch < 0 ||
        owner.length > 256 ||
        install.length > 256) {
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.scopeMismatch,
      );
    }
    final existed = File(path).existsSync();
    if (!allowCreate && !existed) {
      throw const WorkspaceDatabaseException(WorkspaceDatabaseError.missing);
    }
    Database? db;
    try {
      db = sqlite3.open(
        path,
        mode: allowCreate ? OpenMode.readWriteCreate : OpenMode.readWrite,
      );
      // Production checks, never assertions. Ordinary SQLite ignores key pragma.
      if (db.select('PRAGMA cipher_version').isEmpty) {
        throw const WorkspaceDatabaseException(
          WorkspaceDatabaseError.unavailable,
        );
      }
      final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      db.execute('PRAGMA key = "x\'$hex\'"');
      db.execute('PRAGMA temp_store=MEMORY');
      db.execute('PRAGMA synchronous=FULL');
      db.execute('PRAGMA foreign_keys=ON');
      db.execute('PRAGMA busy_timeout=5000');
      if (db.select('PRAGMA temp_store').single.values.single != 2 ||
          db.select('PRAGMA synchronous').single.values.single != 2) {
        throw const WorkspaceDatabaseException(
          WorkspaceDatabaseError.unavailable,
        );
      }
      // Authenticate existing database before migrations or any writes.
      final tables = db.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final version = db.select('PRAGMA user_version').single.values.single;
      if (tables.isEmpty && version == 0 && allowCreate && !existed) {
        db.execute('BEGIN IMMEDIATE');
        try {
          db.execute(
            'CREATE TABLE workspace_scope (one INTEGER PRIMARY KEY CHECK(one=1), owner TEXT NOT NULL, install TEXT NOT NULL, epoch INTEGER NOT NULL)',
          );
          db.execute('INSERT INTO workspace_scope VALUES(1,?,?,?)', [
            owner,
            install,
            epoch,
          ]);
          db.execute(
            'CREATE TABLE workspace_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(kind,id)) WITHOUT ROWID',
          );
          db.execute('PRAGMA user_version=1');
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (version != 1) {
        throw const WorkspaceDatabaseException(
          WorkspaceDatabaseError.lockedOrCorrupt,
        );
      }
      final scope = db.select(
        'SELECT owner,install,epoch FROM workspace_scope WHERE one=1',
      );
      if (scope.length != 1 ||
          scope.single['owner'] != owner ||
          scope.single['install'] != install ||
          scope.single['epoch'] != epoch) {
        throw const WorkspaceDatabaseException(
          WorkspaceDatabaseError.scopeMismatch,
        );
      }
      return EncryptedWorkspaceDatabase._(db, owner, install, epoch);
    } on WorkspaceDatabaseException {
      db?.close();
      rethrow;
    } catch (_) {
      db?.close();
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.lockedOrCorrupt,
      );
    }
  }

  static const _kinds = {
    'snapshot',
    'edit',
    'deletionFloor',
    'settings',
    'profile',
    'syncState',
  };
  void _ready() {
    if (_closed) {
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.unavailable,
      );
    }
  }

  static void _record(String kind, String id) {
    if (!_kinds.contains(kind) || id.isEmpty || id.length > 256) {
      throw const FormatException('Invalid workspace record');
    }
  }

  /// Synchronous callback cannot outlive transaction ownership. Any exception
  /// rolls back snapshot, pending edits and deletion floors as one commit.
  T transaction<T>(T Function() action) {
    _ready();
    if (action is Future Function()) {
      throw StateError('Async workspace transaction');
    }
    if (_inTransaction) throw StateError('Nested workspace transaction');
    _db.execute('BEGIN IMMEDIATE');
    _inTransaction = true;
    try {
      final result = action();
      if (result is Future) throw StateError('Async workspace transaction');
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  /// Writes require an outer transaction to prevent a caller accidentally
  /// committing the UI change without its journal/floor record.
  void put(String kind, String id, Map<String, Object?> payload) {
    _ready();
    _record(kind, id);
    if (!_inTransaction) throw StateError('Workspace transaction required');
    _checkPayload(payload);
    final encoded = jsonEncode(payload);
    if (encoded.length > 4 * 1024 * 1024) {
      throw const FormatException('Workspace record too large');
    }
    _db.execute(
      'INSERT INTO workspace_records(kind,id,payload) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload',
      [kind, id, encoded],
    );
  }

  Map<String, Object?>? read(String kind, String id) {
    _ready();
    _record(kind, id);
    final rows = _db.select(
      'SELECT payload FROM workspace_records WHERE kind=? AND id=?',
      [kind, id],
    );
    if (rows.isEmpty) return null;
    try {
      final payload = jsonDecode(rows.single['payload'] as String);
      if (payload is! Map<String, dynamic>) throw const FormatException();
      _checkPayload(payload);
      return payload;
    } catch (_) {
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.lockedOrCorrupt,
      );
    }
  }

  void remove(String kind, String id) {
    _ready();
    _record(kind, id);
    if (!_inTransaction) throw StateError('Workspace transaction required');
    _db.execute('DELETE FROM workspace_records WHERE kind=? AND id=?', [
      kind,
      id,
    ]);
  }

  void close() {
    if (_closed) return;
    if (_inTransaction) throw StateError('Cannot close active transaction');
    _closed = true;
    _db.close();
  }

  @override
  String toString() => 'EncryptedWorkspaceDatabase(redacted)';
}

// Defense-in-depth guard, not a substitute for typed snapshot serialization.
// Neither credentials nor seeds belong in a UI cache, even when encrypted.
void _checkPayload(Object? value, [int depth = 0]) {
  if (depth > 32) throw const FormatException('Workspace payload too deep');
  if (value is Map) {
    for (final e in value.entries) {
      if (e.key is! String ||
          RegExp(
            r'(seed|secret|password|bearer|token|cookie|privatekey)',
            caseSensitive: false,
          ).hasMatch(e.key as String)) {
        throw const FormatException('Credential field forbidden in workspace');
      }
      _checkPayload(e.value, depth + 1);
    }
  } else if (value is List) {
    for (final item in value) {
      _checkPayload(item, depth + 1);
    }
  } else if (value != null &&
      value is! String &&
      value is! num &&
      value is! bool) {
    throw const FormatException('Invalid workspace payload');
  }
}
