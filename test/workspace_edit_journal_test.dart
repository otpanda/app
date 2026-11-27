import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/workspace_edit_journal.dart';

WorkspaceEdit edit(
  String field,
  Object value,
  int time, {
  String owner = 'owner',
  String entry = 'entry',
  String incarnation = 'v1',
  String device = 'device',
  String? operation,
}) => WorkspaceEdit(
  ownerId: owner,
  entryId: entry,
  incarnation: incarnation,
  field: field,
  value: value,
  stamp: EditStamp(time, device, operation ?? 'op$time'),
);

void main() {
  test('independent fields and tag memberships survive concurrent edits', () {
    final j = WorkspaceEditJournal('owner');
    j.merge([
      edit('label', 'Bank', 10),
      edit('tag/work', true, 11),
    ], local: true);
    j.merge([edit('account', 'person', 12), edit('tag/home', true, 13)]);
    expect(j.value('entry', 'v1', 'label'), 'Bank');
    expect(j.value('entry', 'v1', 'account'), 'person');
    expect(j.value('entry', 'v1', 'tag/work'), true);
    expect(j.value('entry', 'v1', 'tag/home'), true);
  });
  test('latest user edit wins regardless of upload order', () {
    final older = edit('label', 'Old', 10), newer = edit('label', 'New', 20);
    for (final batch in [
      [older, newer],
      [newer, older],
    ]) {
      final j = WorkspaceEditJournal('owner')..merge(batch);
      expect(j.value('entry', 'v1', 'label'), 'New');
    }
  });
  test('deletion wins arbitrarily newer stale metadata and tag changes', () {
    for (final batch in [
      [edit('deleted', true, 10), edit('label', 'Later', 999999)],
      [edit('label', 'Later', 999999), edit('deleted', true, 10)],
    ]) {
      final j = WorkspaceEditJournal('owner')..merge(batch, local: true);
      expect(j.deleted('entry', 'v1'), true);
      expect(j.value('entry', 'v1', 'label'), isNull);
      expect(j.pending.map((e) => e.field), ['deleted']);
      j.merge([edit('label', 'Recreated', 30, incarnation: 'v2')]);
      expect(j.value('entry', 'v2', 'label'), 'Recreated');
      expect(j.deleted('entry', 'v1'), true);
    }
  });
  test('old acknowledgment cannot clear a newer local edit', () {
    final a = edit('label', 'A', 10), b = edit('label', 'B', 20);
    final j = WorkspaceEditJournal('owner')..merge([a], local: true);
    j.merge([b], local: true);
    j.acknowledge(a);
    expect(j.pending.single.value, 'B');
    j.acknowledge(b);
    expect(j.pending, isEmpty);
  });
  test('remote replacement does not become an unsent local edit', () {
    final j = WorkspaceEditJournal('owner')
      ..merge([edit('label', 'A', 10)], local: true);
    j.merge([edit('label', 'B', 20)]);
    expect(j.value('entry', 'v1', 'label'), 'B');
    expect(j.pending.every((e) => e.value != 'B'), true);
    j.acknowledge(edit('label', 'A', 10));
    expect(j.pending, isEmpty);
  });
  test('batch owner validation is atomic', () {
    final j = WorkspaceEditJournal('owner');
    expect(
      () => j.merge([
        edit('label', 'Good', 10),
        edit('label', 'Bad', 20, owner: 'other'),
      ]),
      throwsStateError,
    );
    expect(j.value('entry', 'v1', 'label'), isNull);
  });
  test('inconsistent replay refuses entire merge', () {
    final j = WorkspaceEditJournal('owner')..merge([edit('label', 'A', 10)]);
    expect(
      () => j.merge([edit('account', 'Good', 20), edit('label', 'B', 10)]),
      throwsFormatException,
    );
    expect(j.value('entry', 'v1', 'account'), isNull);
    expect(j.value('entry', 'v1', 'label'), 'A');
  });
  test('stable tie breaker gives same answer in opposite merge orders', () {
    final a = edit('label', 'A', 10, device: 'a'),
        b = edit('label', 'B', 10, device: 'b');
    final x = WorkspaceEditJournal('owner')..merge([a, b]);
    final y = WorkspaceEditJournal('owner')..merge([b, a]);
    expect(x.value('entry', 'v1', 'label'), y.value('entry', 'v1', 'label'));
  });
  test('seed and false-delete metadata never enter the journal', () {
    expect(() => edit('seed', 'sensitive', 10), throwsFormatException);
    expect(() => edit('deleted', false, 10), throwsFormatException);
  });
}
