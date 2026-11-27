import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_workspace_admission.dart';
import 'package:otpanda_client/native/native_workspace_coordinator.dart';
import 'package:otpanda_client/offline_totp/native_offline_workspace_runtime.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';
import 'package:otpanda_client/session_contract.dart';

import '../offline_totp/fake_seed_custody.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('authenticated admission creates once, confirms, cold discovers independently and logout invalidates', () async {
    final dir = Directory.systemTemp.createTempSync('workspace-coordinator-');
    final keys = FakeSecretStore(), custody = FakeSeedCustody();
    final runtime = NativeOfflineWorkspaceRuntime(clock: () => 59000);
    final scope = {
      'owner': 'owner',
      'install': 'A' * 43,
      'epoch': 0,
      'namespace': 'workspace',
      'path': '${dir.path}/db',
    };
    var ready = false, active = false, unlocked = true, creates = 0;
    const channel = MethodChannel('test/admission');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'admit':
              creates++;
              active = true;
              return {'scope': scope, 'createAllowed': creates == 1};
            case 'confirm':
              ready = true;
              return {'scope': scope};
            case 'discover':
              return {
                'status': active && ready ? 'ready' : 'absent',
                'scope': active && ready ? scope : null,
                'reason': null,
                'createAllowed': false,
              };
            case 'invalidate':
              active = false;
              return {'invalidated': true};
          }
          throw StateError('unexpected method');
        });
    final c = NativeWorkspaceCoordinator(
      admission: NativeWorkspaceAdmission(channel: channel),
      custody: custody,
      keys: keys,
      runtime: runtime,
      locallyUnlocked: () => unlocked,
    );
    try {
      await c.admitAuthenticated('owner');
      expect(ready, true);
      expect(creates, 1);
      runtime.publishAuthenticated(
        NativeWorkspaceSnapshot(
          ownerId: 'owner',
          installId: 'A' * 43,
          epoch: 0,
          savedAtMs: 59000,
          entries: [
            const ManagedEntry('entry', 'Saved service', 'me', true, true),
          ],
          codes: [],
          sources: [],
          unassigned: [],
        ),
      );
      unlocked = false;
      c.localLockChanged();
      expect(runtime.snapshot, isNull);
      unlocked = true;
      await c.discover();
      expect(runtime.snapshot!.entries.single.service, 'Saved service');
      expect(creates, 1);
      await c.invalidate();
      expect(active, false);
      await c.discover();
      expect(c.hasLocalView, false);
    } finally {
      c.dispose();
      runtime.dispose();
      dir.deleteSync(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
  for (final deleteDb in [false, true]) {
    test(
      'one-shot bootstrap retry refuses replacement: delete DB $deleteDb',
      () async {
        final dir = Directory.systemTemp.createTempSync('admission-oneshot-');
        final keys = FakeSecretStore(), custody = FakeSeedCustody();
        final runtime = NativeOfflineWorkspaceRuntime(clock: () => 59000);
        final scope = {
          'owner': 'owner',
          'install': 'A' * 43,
          'epoch': 0,
          'namespace': 'workspace',
          'path': '${dir.path}/db',
        };
        var grants = 0, confirmations = 0;
        const channel = MethodChannel('test/admission-oneshot');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'admit')
                return {'scope': scope, 'createAllowed': grants++ == 0};
              if (call.method == 'confirm') {
                confirmations++;
                throw PlatformException(code: 'UNAVAILABLE');
              }
              throw StateError('unexpected');
            });
        final c = NativeWorkspaceCoordinator(
          admission: NativeWorkspaceAdmission(channel: channel),
          custody: custody,
          keys: keys,
          runtime: runtime,
          locallyUnlocked: () => true,
        );
        try {
          await c.admitAuthenticated('owner');
          expect(confirmations, 1);
          c.lock();
          if (deleteDb) {
            File('${dir.path}/db').deleteSync();
          } else {
            await keys.delete('workspace');
          }
          await c.admitAuthenticated('owner');
          expect(c.hasLocalView, false);
          expect(c.unavailable, true);
          expect(confirmations, 1);
        } finally {
          c.dispose();
          runtime.dispose();
          dir.deleteSync(recursive: true);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
  test(
    'logout invalidates a native admit whose reply is still in flight',
    () async {
      final reply = Completer<Object?>(), entered = Completer<void>();
      final runtime = NativeOfflineWorkspaceRuntime(clock: () => 59000);
      var invalidations = 0;
      const channel = MethodChannel('test/admission-flight');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'admit') {
              entered.complete();
              return reply.future;
            }
            if (call.method == 'invalidate') {
              invalidations++;
              return {'invalidated': true};
            }
            throw StateError('unexpected');
          });
      final c = NativeWorkspaceCoordinator(
        admission: NativeWorkspaceAdmission(channel: channel),
        custody: FakeSeedCustody(),
        keys: FakeSecretStore(),
        runtime: runtime,
        locallyUnlocked: () => true,
      );
      final pending = c.admitAuthenticated('owner');
      await entered.future;
      final logout = c.invalidate();
      reply.complete({
        'scope': {
          'owner': 'owner',
          'install': 'A' * 43,
          'epoch': 0,
          'namespace': 'workspace',
          'path': '/never-open',
        },
        'createAllowed': true,
      });
      await pending;
      await logout;
      expect(invalidations, 1);
      expect(c.hasLocalView, false);
      c.dispose();
      runtime.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
  test(
    'discovery rejects forged create authority and malformed scope',
    () async {
      const channel = MethodChannel('test/admission-reject');
      final adapter = NativeWorkspaceAdmission(channel: channel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {
              'status': 'ready',
              'scope': {},
              'reason': null,
              'createAllowed': true,
            },
          );
      await expectLater(adapter.discover(), throwsFormatException);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );
}
