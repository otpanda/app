import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/encrypted_workspace_database.dart';

void main() {
  late Directory dir;
  late String path;
  final key = Uint8List.fromList(List.filled(32, 51));
  EncryptedWorkspaceDatabase open({
    bool create = true,
    String owner = 'owner',
    int epoch = 2,
    Uint8List? withKey,
  }) => EncryptedWorkspaceDatabase.open(
    path: path,
    key: withKey ?? key,
    owner: owner,
    install: 'install',
    epoch: epoch,
    allowCreate: create,
  );
  setUp(() {
    dir = Directory.systemTemp.createTempSync('otpanda-cipher-test-');
    path = '${dir.path}/db';
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });
  test('snapshot and pending edit commit then survive reopen encrypted', () {
    var db = open();
    db.transaction(() {
      db.put('snapshot', 'entries', {'label': 'PRIVATE_TEST_LABEL_89207289'});
      db.put('edit', 'op1', {
        'field': 'label',
        'value': 'PRIVATE_TEST_LABEL_89207289',
      });
    });
    db.close();
    expect(
      String.fromCharCodes(File(path).readAsBytesSync()),
      isNot(contains('PRIVATE_TEST_LABEL_89207289')),
    );
    db = open(create: false);
    expect(
      db.read('snapshot', 'entries')?['label'],
      'PRIVATE_TEST_LABEL_89207289',
    );
    expect(db.read('edit', 'op1')?['field'], 'label');
    db.close();
  });
  test('exception rolls back both UI and journal', () {
    final db = open();
    expect(
      () => db.transaction<void>(() {
        db.put('snapshot', 'entries', {'label': 'no'});
        db.put('edit', 'op1', {'field': 'label'});
        throw StateError('injected');
      }),
      throwsStateError,
    );
    expect(db.read('snapshot', 'entries'), isNull);
    expect(db.read('edit', 'op1'), isNull);
    db.close();
  });
  test('wrong key, scope or epoch never resets file', () {
    final db = open();
    db.transaction(() => db.put('settings', 'one', {'enabled': true}));
    db.close();
    final bytes = File(path).readAsBytesSync();
    expect(
      () => open(owner: 'other'),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
    expect(() => open(epoch: 3), throwsA(isA<WorkspaceDatabaseException>()));
    expect(
      () => open(withKey: Uint8List(32)),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
    expect(File(path).readAsBytesSync(), bytes);
    final reopened = open();
    expect(reopened.read('settings', 'one')?['enabled'], true);
    reopened.close();
  });
  test('tamper fails closed and preserves bytes', () {
    final db = open();
    db.close();
    final bytes = File(path).readAsBytesSync();
    bytes[100] ^= 1;
    File(path).writeAsBytesSync(bytes, flush: true);
    expect(() => open(), throwsA(isA<WorkspaceDatabaseException>()));
    expect(File(path).readAsBytesSync(), bytes);
  });
  test('missing does not silently create when not admitted', () {
    expect(
      () => open(create: false),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
    expect(File(path).existsSync(), false);
  });
  test('credential fields and nontransactional writes rejected', () {
    final db = open();
    expect(() => db.put('snapshot', 'a', {'label': 'a'}), throwsStateError);
    expect(
      () => db.transaction(
        () => db.put('snapshot', 'a', {
          'nested': {'seed': 'test'},
        }),
      ),
      throwsFormatException,
    );
    expect(
      () => db.transaction(
        () => db.put('snapshot', 'a', {'accessToken': 'test'}),
      ),
      throwsFormatException,
    );
    expect(db.read('snapshot', 'a'), isNull);
    db.close();
  });
  test('nested and async transactions refused without committing', () {
    final db = open();
    expect(
      () => db.transaction(() => db.transaction(() => 0)),
      throwsStateError,
    );
    expect(
      () => db.transaction(() async {
        db.put('snapshot', 'a', {'label': 'a'});
      }),
      throwsStateError,
    );
    expect(db.read('snapshot', 'a'), isNull);
    db.close();
  });
}
