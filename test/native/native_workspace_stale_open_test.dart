import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_workspace_admission.dart';
import 'package:otpanda_client/native/native_workspace_coordinator.dart';
import 'package:otpanda_client/offline_totp/native_offline_workspace_runtime.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';

import '../offline_totp/fake_seed_custody.dart';

class _HeldKeys implements SecretStore {
  final backing = FakeSecretStore();
  final entered = Completer<void>(), release = Completer<void>();
  bool held = false;
  @override
  String get kind => 'held-test';
  @override
  Future<Uint8List?> read(String name) async {
    if (!held) {
      held = true;
      entered.complete();
      await release.future;
    }
    return backing.read(name);
  }

  @override
  Future<Uint8List> createIfAbsent(String name, Uint8List candidate) =>
      backing.createIfAbsent(name, candidate);
  @override
  Future<void> delete(String name) => backing.delete(name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final localLock in [false, true]) {
    test(
      'stale open: local lock=$localLock, cold reopen only while locally active',
      () async {
        final dir = Directory.systemTemp.createTempSync('stale-open-');
        final runtime = NativeOfflineWorkspaceRuntime(clock: () => 59000);
        final keys = _HeldKeys();
        var session = true, unlocked = true, confirms = 0, discoveries = 0;
        final scope = {
          'owner': 'owner',
          'install': 'A' * 43,
          'epoch': 0,
          'namespace': 'workspace',
          'path': '${dir.path}/db',
        };
        const channel = MethodChannel('test/stale-open');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'admit') {
                return {'scope': scope, 'createAllowed': true};
              }
              if (call.method == 'confirm') {
                confirms++;
                return {'scope': scope};
              }
              if (call.method == 'discover') {
                discoveries++;
                return {
                  'status': 'ready',
                  'scope': scope,
                  'reason': null,
                  'createAllowed': false,
                };
              }
              throw StateError('unexpected');
            });
        final coordinator = NativeWorkspaceCoordinator(
          admission: NativeWorkspaceAdmission(channel: channel),
          custody: FakeSeedCustody(),
          keys: keys,
          runtime: runtime,
          locallyUnlocked: () => unlocked,
        );
        try {
          final pending = coordinator.admitAuthenticated(
            'owner',
            stillCurrent: () => session,
          );
          await keys.entered.future;
          session = false;
          if (localLock) {
            unlocked = false;
            coordinator.lock();
          }
          keys.release.complete();
          await pending;
          // Queue barrier: stale cleanup and any scheduled cold rediscovery must finish first.
          await coordinator.discover();
          expect(confirms, 0);
          if (localLock) {
            expect(discoveries, 0);
            expect(runtime.phase, NativeOfflineWorkspacePhase.locked);
            expect(coordinator.scope, isNull);
          } else {
            expect(discoveries, greaterThanOrEqualTo(1));
            expect(runtime.phase, NativeOfflineWorkspacePhase.ready);
            expect(coordinator.scope?.owner, 'owner');
          }
        } finally {
          coordinator.dispose();
          runtime.dispose();
          dir.deleteSync(recursive: true);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
}
