import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/offline_totp/encrypted_workspace_database.dart';
import 'package:otpanda_client/offline_totp/native_workspace_cache.dart';
import 'package:otpanda_client/offline_totp/native_workspace_cache_binding.dart';

import 'product_shell_test.dart' show FakeTransport, routes;

void main() {
  test('fresh authenticated refresh persists and cold controller hydrates without a request', () async {
    final dir = Directory.systemTemp.createTempSync('cache-binding-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = EncryptedWorkspaceDatabase.open(
      path: '${dir.path}/db',
      key: Uint8List.fromList(List.filled(32, 3)),
      owner: 'o',
      install: 'i',
      epoch: 1,
      allowCreate: true,
    );
    addTearDown(db.close);
    final cache = NativeWorkspaceCache(db);
    final tr = FakeTransport(
      routes(
        entries: [
          {
            'entry_id': 'a',
            'service_name': 'Cached service',
            'account_name': 'me',
            'capabilities': {'manage': true},
          },
        ],
      ),
    );
    final c = ReadWorkspaceController(bridge: tr, clock: () => 1000000);
    addTearDown(c.dispose);
    final binding = NativeWorkspaceCacheBinding(
      controller: c,
      cache: cache,
      owner: 'o',
      install: 'i',
      epoch: 1,
      stillUnlocked: () => true,
      clock: () => 1000000,
    );
    await c.refresh();
    expect(cache.read()!.entries.single.service, 'Cached service');
    binding.close();
    final coldTr = FakeTransport(routes());
    final cold = ReadWorkspaceController(bridge: coldTr, clock: () => 1000000);
    addTearDown(cold.dispose);
    final coldBinding = NativeWorkspaceCacheBinding(
      controller: cold,
      cache: cache,
      owner: 'o',
      install: 'i',
      epoch: 1,
      stillUnlocked: () => true,
      clock: () => 1000000,
    );
    addTearDown(coldBinding.close);
    coldBinding.hydrate();
    expect(coldTr.calls, 0);
    expect(cold.store.entries.single.service, 'Cached service');
    expect(cold.store.entries.single.manage, false);
  });
  test('closed or locked binding cannot hydrate', () {
    final dir = Directory.systemTemp.createTempSync('cache-lock-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = EncryptedWorkspaceDatabase.open(
      path: '${dir.path}/db',
      key: Uint8List.fromList(List.filled(32, 3)),
      owner: 'o',
      install: 'i',
      epoch: 1,
      allowCreate: true,
    );
    addTearDown(db.close);
    final c = ReadWorkspaceController(bridge: FakeTransport(routes()));
    addTearDown(c.dispose);
    final b = NativeWorkspaceCacheBinding(
      controller: c,
      cache: NativeWorkspaceCache(db),
      owner: 'o',
      install: 'i',
      epoch: 1,
      stillUnlocked: () => false,
      clock: () => 1000000,
    );
    expect(b.hydrate, throwsStateError);
    b.close();
    expect(b.hydrate, throwsStateError);
  });
}
