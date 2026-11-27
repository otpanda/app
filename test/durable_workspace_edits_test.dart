import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/durable_workspace_edits.dart';
import 'package:otpanda_client/offline_totp/encrypted_workspace_database.dart';
import 'package:otpanda_client/offline_totp/native_workspace_cache.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';
import 'package:otpanda_client/offline_totp/workspace_edit_journal.dart';

void main() {
  late Directory dir;
  late EncryptedWorkspaceDatabase db;
  late String path;
  EncryptedWorkspaceDatabase open() => EncryptedWorkspaceDatabase.open(
    path: path,
    key: Uint8List(32),
    owner: 'owner',
    install: 'install',
    epoch: 1,
    allowCreate: !File(path).existsSync(),
  );
  setUp(() {
    dir = Directory.systemTemp.createTempSync('otpanda-edits-');
    path = '${dir.path}/db';
    db = open();
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });
  NativeWorkspaceSnapshot snapshot() => NativeWorkspaceSnapshot(
    ownerId: 'owner',
    installId: 'install',
    epoch: 1,
    savedAtMs: 1000,
    entries: [],
    codes: [],
    sources: [],
    unassigned: [],
  );
  WorkspaceEdit edit(String value, int time) => WorkspaceEdit(
    ownerId: 'owner',
    entryId: 'entry',
    incarnation: 'v1',
    field: 'label',
    value: value,
    stamp: EditStamp(time, 'device', 'op$time'),
  );
  test('snapshot and pending intent survive restart together', () {
    DurableWorkspaceEdits(db).applyLocal(snapshot(), [edit('A', 10)]);
    db.close();
    db = open();
    expect(NativeWorkspaceCache(db).read(), isNotNull);
    expect(DurableWorkspaceEdits(db).read().pending.single.value, 'A');
  });
  test('remote newer winner does not become pending and retires stale local intent', () {
    final store = DurableWorkspaceEdits(db);
    store.applyLocal(snapshot(), [edit('A', 10)]);
    store.mergeRemote([edit('B', 20)]);
    db.close();
    db = open();
    final j = DurableWorkspaceEdits(db).read();
    expect(j.value('entry', 'v1', 'label'), 'B');
    expect(j.pending, isEmpty);
  });
  test('old acknowledgment cannot clear newer local intent across reopen', () {
    var store = DurableWorkspaceEdits(db);
    store.applyLocal(snapshot(), [edit('A', 10)]);
    store.applyLocal(snapshot(), [edit('B', 20)]);
    db.close();
    db = open();
    store = DurableWorkspaceEdits(db);
    store.acknowledge(edit('A', 10));
    expect(store.read().pending.single.value, 'B');
    store.acknowledge(edit('B', 20));
    expect(store.read().pending, isEmpty);
  });
  test('deletion survives restart and suppresses ordinary metadata', () {
    final deletion = WorkspaceEdit(
      ownerId: 'owner',
      entryId: 'entry',
      incarnation: 'v1',
      field: 'deleted',
      value: true,
      stamp: EditStamp(30, 'device', 'delete'),
    );
    DurableWorkspaceEdits(db)
        .applyLocal(snapshot(), [deletion, edit('Stale', 99999)]);
    db.close();
    db = open();
    final j = DurableWorkspaceEdits(db).read();
    expect(j.deleted('entry', 'v1'), true);
    expect(j.value('entry', 'v1', 'label'), isNull);
    expect(j.pending.single.field, 'deleted');
    expect(db.records('deletionFloor').length, 1);
  });
  test('orphan deletion floor refuses hydration rather than resurrection', () {
    db.transaction(
      () => db.put('deletionFloor', '["entry","v1"]', {
        'entry': 'entry',
        'incarnation': 'v1',
      }),
    );
    expect(
      () => DurableWorkspaceEdits(db).read(),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
  });
  test('invalid owner batch leaves both snapshot and journal absent', () {
    final bad = WorkspaceEdit(
      ownerId: 'other',
      entryId: 'entry',
      incarnation: 'v1',
      field: 'label',
      value: 'bad',
      stamp: EditStamp(10, 'device', 'op10'),
    );
    expect(
      () =>
          DurableWorkspaceEdits(db)
              .applyLocal(snapshot(), [edit('A', 10), bad]),
      throwsStateError,
    );
    expect(NativeWorkspaceCache(db).read(), isNull);
    expect(DurableWorkspaceEdits(db).read().pending, isEmpty);
  });
}
