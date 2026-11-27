import 'dart:convert';

import 'encrypted_workspace_database.dart';
import 'native_workspace_snapshot.dart';
import 'workspace_edit_journal.dart';

/// Persists UI, metadata conflict winners, local pending writes and tombstones
/// within one SQLCipher transaction. No remote request or seed handling.
final class DurableWorkspaceEdits {
  DurableWorkspaceEdits(this.database);
  final EncryptedWorkspaceDatabase database;

  String _key(WorkspaceEdit e) =>
      jsonEncode([e.entryId, e.incarnation, e.field]);
  WorkspaceEditJournal _load() {
    final j = WorkspaceEditJournal(database.owner);
    final rows = database.records('edit');
    final parsed = <({WorkspaceEdit edit, bool pending})>[];
    for (final row in rows.entries) {
      final payload = row.value;
      final pending = payload['pending'];
      final raw = payload['edit'];
      if (payload.length != 2 ||
          pending is! bool ||
          raw is! Map<String, dynamic>) {
        throw const WorkspaceDatabaseException(
          WorkspaceDatabaseError.lockedOrCorrupt,
        );
      }
      final e = WorkspaceEdit.fromJson(raw);
      if (row.key != _key(e)) {
        throw const FormatException('Stored edit key mismatch');
      }
      parsed.add((edit: e, pending: pending));
    }
    // Reconstruct all winners before marking local edits. No inferred pending.
    j.merge(parsed.where((r) => !r.pending).map((r) => r.edit));
    j.merge(parsed.where((r) => r.pending).map((r) => r.edit), local: true);
    for (final floor in database.records('deletionFloor').entries) {
      final entry = floor.value['entry'],
          incarnation = floor.value['incarnation'];
      if (floor.value.length != 2 ||
          entry is! String ||
          incarnation is! String ||
          floor.key != jsonEncode([entry, incarnation]) ||
          !j.deleted(entry, incarnation)) {
        throw const WorkspaceDatabaseException(
          WorkspaceDatabaseError.lockedOrCorrupt,
        );
      }
    }
    return j;
  }

  WorkspaceEditJournal read() => database.transaction(_load);

  /// Caller supplies the already-validated optimistic snapshot. Writes fail
  /// together, never leave UI committed without durable pending intent.
  void applyLocal(
    NativeWorkspaceSnapshot snapshot,
    Iterable<WorkspaceEdit> edits,
  ) {
    if (snapshot.ownerId != database.owner ||
        snapshot.installId != database.install ||
        snapshot.epoch != database.epoch) {
      throw const WorkspaceDatabaseException(
        WorkspaceDatabaseError.scopeMismatch,
      );
    }
    database.transaction(() {
      final journal = _load();
      journal.merge(edits, local: true);
      database.put('snapshot', 'ui', snapshot.toJson());
      _save(journal);
    });
  }

  void mergeRemote(Iterable<WorkspaceEdit> edits) => database.transaction(() {
    final journal = _load();
    journal.merge(edits);
    _save(journal);
  });
  void acknowledge(WorkspaceEdit edit) => database.transaction(() {
    final journal = _load();
    journal.acknowledge(edit);
    _save(journal);
  });
  void _save(WorkspaceEditJournal j) {
    final pending = j.pending.map(_key).toSet();
    for (final old in database.records('edit').keys) {
      database.remove('edit', old);
    }
    for (final e in j.latest) {
      database.put('edit', _key(e), {
        'edit': e.toJson(),
        'pending': pending.contains(_key(e)),
      });
      if (e.field == 'deleted') {
        database.put('deletionFloor', jsonEncode([e.entryId, e.incarnation]), {
          'entry': e.entryId,
          'incarnation': e.incarnation,
        });
      }
    }
  }

  @override
  String toString() => 'DurableWorkspaceEdits(redacted)';
}
