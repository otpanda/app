/// Pure conflict model for the encrypted native workspace. This file does not
/// persist data, carry TOTP seeds, authorize a mutation, or contact the server.
/// Persistence and server synchronization must commit these records together
/// with the owner's existing epoch and deletion floors.
library;

/// Stable edit time, assigned when the person edits, never when a retry uploads.
/// Device and operation identifiers break equal-time ties deterministically.
final class EditStamp implements Comparable<EditStamp> {
  EditStamp(this.editedAtMs, this.deviceId, this.operationId) {
    if (editedAtMs < 0 || !_id(deviceId) || !_id(operationId)) {
      throw const FormatException('Invalid edit stamp');
    }
  }
  final int editedAtMs;
  final String deviceId, operationId;
  @override
  int compareTo(EditStamp other) {
    final time = editedAtMs.compareTo(other.editedAtMs);
    if (time != 0) return time;
    final device = deviceId.compareTo(other.deviceId);
    return device != 0 ? device : operationId.compareTo(other.operationId);
  }

  @override
  String toString() => 'EditStamp(redacted)';
}

bool _id(String s) => RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(s);

/// Membership fields are separate per tag, so concurrently adding different
/// tags cannot replace the whole tag set. Seed creation/import is intentionally
/// outside this model and must enter the custody path, never a metadata field.
final class WorkspaceEdit {
  WorkspaceEdit({
    required this.ownerId,
    required this.entryId,
    required this.incarnation,
    required this.field,
    required this.value,
    required this.stamp,
  }) {
    if (!_id(ownerId) || !_id(entryId) || !_id(incarnation)) {
      throw const FormatException('Invalid edit scope');
    }
    final text = field == 'label' || field == 'account';
    final flag =
        field == 'pinned' ||
        field == 'deleted' ||
        (field.startsWith('tag/') && _id(field.substring(4)));
    if ((!text && !flag) ||
        (text && (value is! String || (value as String).length > 256)) ||
        (flag && value is! bool) ||
        (field == 'deleted' && value != true)) {
      throw const FormatException('Invalid workspace edit');
    }
  }
  final String ownerId, entryId, incarnation, field;
  final Object value;
  final EditStamp stamp;
  String get _key => '$entryId/$incarnation/$field';
  @override
  String toString() => 'WorkspaceEdit(redacted)';
}

/// A deleted incarnation cannot be resurrected by later ordinary edits, even
/// edits with a newer timestamp. Explicit restore/recreate uses a fresh
/// incarnation through its own authorized lifecycle, not deleted=false.
final class WorkspaceEditJournal {
  WorkspaceEditJournal(this.ownerId) {
    if (!_id(ownerId)) throw const FormatException('Invalid owner');
  }
  final String ownerId;
  final Map<String, WorkspaceEdit> _latest = {};
  final Map<String, WorkspaceEdit> _pending = {};
  String _subject(String entryId, String incarnation) =>
      '$entryId/$incarnation';
  final Set<String> _deleted = {};

  bool deleted(String entryId, String incarnation) =>
      _deleted.contains(_subject(entryId, incarnation));

  /// Validates the entire input before changing anything. Remote receipts do
  /// not mark unrelated local edits synced; the exact stamp must be acked.
  void merge(Iterable<WorkspaceEdit> edits, {bool local = false}) {
    final batch = edits.toList();
    if (batch.any((e) => e.ownerId != ownerId)) {
      throw StateError('Workspace owner mismatch');
    }
    // The same stable operation cannot carry two different values. An
    // inconsistent replay is corruption, never a tie to resolve arbitrarily.
    final candidates = Map<String, WorkspaceEdit>.from(_latest);
    for (final e in batch) {
      final prior = candidates[e._key];
      if (prior != null &&
          prior.stamp.compareTo(e.stamp) == 0 &&
          prior.value != e.value) {
        throw const FormatException('Inconsistent edit replay');
      }
      if (prior == null || prior.stamp.compareTo(e.stamp) < 0) {
        candidates[e._key] = e;
      }
    }
    for (final e in batch) {
      if (e.field == 'deleted') {
        _deleted.add(_subject(e.entryId, e.incarnation));
      }
    }
    _latest
      ..clear()
      ..addAll(candidates);
    if (local) {
      for (final e in batch) {
        if (identical(_latest[e._key], e)) _pending[e._key] = e;
      }
    }
  }

  Object? value(String entryId, String incarnation, String field) {
    if (deleted(entryId, incarnation)) return null;
    return _latest['$entryId/$incarnation/$field']?.value;
  }

  List<WorkspaceEdit> get pending => List.unmodifiable(
    _pending.values.where(
      (e) => e.field == 'deleted' || !deleted(e.entryId, e.incarnation),
    ),
  );

  /// An old server acknowledgment cannot erase a newer unsent local edit.
  void acknowledge(WorkspaceEdit edit) {
    if (edit.ownerId != ownerId) throw StateError('Workspace owner mismatch');
    final pending = _pending[edit._key];
    if (pending != null &&
        pending.stamp.compareTo(edit.stamp) == 0 &&
        pending.value == edit.value) {
      _pending.remove(edit._key);
    }
  }

  @override
  String toString() => 'WorkspaceEditJournal(redacted)';
}
