import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/offline_totp/encrypted_workspace_database.dart';
import 'package:otpanda_client/offline_totp/native_workspace_cache.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';

void main() {
  NativeWorkspaceSnapshot snap({String owner = 'owner', int epoch = 1}) =>
      NativeWorkspaceSnapshot(
        ownerId: owner,
        installId: 'install',
        epoch: epoch,
        savedAtMs: 1000,
        entries: [
          const ManagedEntry(
            'entry',
            'PRIVATE_LABEL',
            'user',
            false,
            true,
            'example.com',
            'Issuer',
            6,
            900,
          ),
        ],
        codes: [
          ReceivedCode.fromJson({
            'entryId': 'entry',
            'code': '123456',
            'receivedAt': 1000,
            'expiresAt': 30000,
          }),
        ],
        sources: [const PrivateSource('source', 'gmail', 'Personal')],
        unassigned: [
          UnassignedCode.fromJson({
            'sourceId': 'source',
            'eventId': 'event',
            'code': '987654',
            'receivedAt': 1000,
            'expiresAt': 30000,
          }),
        ],
      );
  test(
    'typed encrypted roundtrip survives restart without restoring a session',
    () {
      final dir = Directory.systemTemp.createTempSync('otpanda-cache-test-');
      final path = '${dir.path}/db';
      final key = Uint8List(32);
      EncryptedWorkspaceDatabase open() => EncryptedWorkspaceDatabase.open(
        path: path,
        key: key,
        owner: 'owner',
        install: 'install',
        epoch: 1,
        allowCreate: !File(path).existsSync(),
      );
      var db = open();
      NativeWorkspaceCache(db).save(snap());
      db.close();
      expect(
        String.fromCharCodes(File(path).readAsBytesSync()),
        isNot(contains('PRIVATE_LABEL')),
      );
      db = open();
      final restored = NativeWorkspaceCache(db).read()!;
      expect(restored.entries.single.service, 'PRIVATE_LABEL');
      expect(restored.entries.single.manage, false);
      expect(restored.entries.single.catalogId, 'example.com');
      expect(restored.entries.single.createdAt, 900);
      expect(restored.activeCodes(29999).single.value, '123456');
      expect(restored.activeCodes(30000), isEmpty);
      expect(restored.activeUnassigned(30000), isEmpty);
      expect(restored.activeCodes(999), isEmpty);
      db.close();
      dir.deleteSync(recursive: true);
    },
  );
  test('owner and epoch mismatch refuse save without writing', () {
    final dir = Directory.systemTemp.createTempSync('otpanda-cache-test-');
    final db = EncryptedWorkspaceDatabase.open(
      path: '${dir.path}/db',
      key: Uint8List(32),
      owner: 'owner',
      install: 'install',
      epoch: 1,
      allowCreate: true,
    );
    final cache = NativeWorkspaceCache(db);
    expect(
      () => cache.save(snap(owner: 'other')),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
    expect(
      () => cache.save(snap(epoch: 2)),
      throwsA(isA<WorkspaceDatabaseException>()),
    );
    expect(cache.read(), isNull);
    db.close();
    dir.deleteSync(recursive: true);
  });
  test('malformed payload and orphan code rows rejected whole', () {
    final payload =
        jsonDecode(jsonEncode(snap().toJson())) as Map<String, Object?>;
    (payload['codes'] as List).add({
      'entryId': 'other',
      'code': '123456',
      'receivedAt': 1000,
      'expiresAt': 30000,
    });
    expect(
      () => NativeWorkspaceSnapshot.fromJson(payload),
      throwsFormatException,
    );
    payload['extra'] = true;
    expect(
      () => NativeWorkspaceSnapshot.fromJson(payload),
      throwsFormatException,
    );
  });
}
