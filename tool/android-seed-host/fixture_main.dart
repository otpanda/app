// Debug-only synthetic entrypoint, no network and no production session.
import 'dart:convert';
import 'dart:io';

import 'package:otpanda_client/native/native_workspace_admission.dart';
import 'package:otpanda_client/native/native_offline_workspace_page.dart';
import 'package:otpanda_client/offline_totp/android_wrapping_key_store.dart';
import 'package:otpanda_client/offline_totp/native_offline_workspace_runtime.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';
import 'package:otpanda_client/session_contract.dart';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/offline_totp/seed_install_id.dart';
import 'package:otpanda_client/offline_totp/seed_install_id_channel.dart';
import 'package:otpanda_client/offline_totp/seed_status_channel.dart';
import 'package:otpanda_client/offline_totp/seed_sync_channel.dart';
import 'package:otpanda_client/offline_totp/android_seed_custody.dart';
import 'package:otpanda_client/offline_totp/native_seed_custody.dart';

const channel = MethodChannel('app.otpanda/seed-custody');
const driver = MethodChannel('seedfx/driver');
const owner = 'fixture-owner';
final localRuntime = NativeOfflineWorkspaceRuntime(clock: () => 59000);
final workspaceAdmission = NativeWorkspaceAdmission();

Future<void> workspaceCheck(bool create) async {
  final NativeWorkspaceScope scope;
  if (create) {
    final admitted = await workspaceAdmission.admit(owner, 0);
    await check('workspace_one_create', admitted.create);
    scope = admitted.scope;
    await check(
      'workspace_retry_no_create',
      !(await workspaceAdmission.admit(owner, 0)).create,
    );
  } else {
    scope = (await workspaceAdmission.discover())!;
    await check(
      'workspace_cold_scope',
      scope.owner == owner && scope.epoch == 0,
    );
  }
  await localRuntime.open(
    keys: AndroidWrappingKeyStore(),
    custody: AndroidSeedCustody(channel: channel),
    namespace: scope.namespace,
    path: scope.path,
    owner: scope.owner,
    install: scope.install,
    epoch: scope.epoch,
    admittedFreshWorkspace: create,
    stillLocallyUnlocked: () => true,
  );
  await check(
    'workspace_database_open',
    localRuntime.phase == NativeOfflineWorkspacePhase.ready,
  );
  if (create) {
    localRuntime.publishAuthenticated(
      NativeWorkspaceSnapshot(
        ownerId: owner,
        installId: scope.install,
        epoch: 0,
        savedAtMs: 59000,
        entries: [
          const ManagedEntry(
            'sealed-entry',
            'Synthetic offline service',
            'fixture',
            true,
            true,
          ),
        ],
        codes: [],
        sources: [],
        unassigned: [],
      ),
    );
    await workspaceAdmission.confirm(scope);
    final bytes = await File(scope.path).readAsBytes();
    await check(
      'workspace_encrypted_disk',
      !utf8
              .decode(bytes, allowMalformed: true)
              .contains('Synthetic offline service') &&
          !utf8.decode(bytes, allowMalformed: true).startsWith('SQLite format'),
    );
  } else {
    await check(
      'workspace_cold_metadata',
      localRuntime.snapshot?.entries.single.service ==
          'Synthetic offline service',
    );
  }
  await localRuntime.refreshLocalCodes();
  await check(
    'workspace_local_code',
    localRuntime.visibleCodes.single.value == '94287082',
  );
  runApp(
    MaterialApp(
      home: NativeOfflineWorkspacePage(
        runtime: localRuntime,
        clock: () => 59000,
        onReconnect: () {},
      ),
    ),
  );
}

Future<T?> call<T>(String method, [Map<String, Object?> args = const {}]) =>
    channel.invokeMethod<T>(method, args);
Future<void> check(String label, bool ok) async {
  await driver.invokeMethod('log', {'label': label, 'ok': ok});
  if (!ok) throw StateError(label);
}

Future<void> refuses(
  String label,
  String method,
  Map<String, Object?> args,
  Set<String> codes,
) async {
  try {
    await call<Object?>(method, args);
    await check(label, false);
  } on PlatformException catch (e) {
    await check(label, codes.contains(e.code));
  }
}

Future<void> proof(String key, Uint8List pub) async {
  const challenge = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  final expiry = DateTime.now().millisecondsSinceEpoch + 60000;
  final sig = await call<String>('syncStatusSign', {
    'owner': owner,
    'keyId': key,
    'challenge': challenge,
    'expiresAt': expiry,
  });
  await check(
    'signature_verifies',
    await driver.invokeMethod<bool>('verify', {
          'publicKey': pub,
          'keyId': key,
          'challenge': challenge,
          'expiresAt': expiry,
          'signature': sig,
        }) ==
        true,
  );
  await refuses(
    'wrong_key_refused',
    'syncStatusSign',
    {
      'owner': owner,
      'keyId': 'f' * 32,
      'challenge': challenge,
      'expiresAt': expiry,
    },
    {'WIRE_KEY'},
  );
}

Future<void> sealedCheck(SeedSyncChannel sync) async {
  final custody = AndroidSeedCustody(channel: channel);
  for (final tamper in [true, false]) {
    final batch = await sync.begin(
      owner: owner,
      deviceId: 'device',
      generation: 1,
      epoch: 0,
      entries: const [SeedBatchEntry('sealed-entry', 1, 'SHA-1', 8, 30)],
    );
    try {
      await sync.bind(
        batch.handleId,
        challenge: 'A' * 43,
        expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
      );
      await sync.signBatch(batch.handleId);
      final sealed = (await driver.invokeMethod<Map>('seal', {
        'ephemeral': batch.ephemeralPublic,
      }))!;
      var ciphertext = sealed['ciphertext'] as String;
      if (tamper) {
        final bytes = base64Url.decode(base64Url.normalize(ciphertext));
        bytes[0] ^= 1;
        ciphertext = base64UrlEncode(bytes).replaceAll('=', '');
      }
      try {
        final pending = await sync.open(
          batch.handleId,
          entryId: 'sealed-entry',
          serverPublicKey: sealed['serverPublicKey'] as String,
          nonce: sealed['nonce'] as String,
          ciphertext: ciphertext,
        );
        await check('sealed_open_complete', !tamper && pending.isEmpty);
      } on SeedSyncFailure catch (e) {
        if (!tamper) rethrow;
        await check(
          'sealed_tamper_refused',
          e.kind == SeedSyncFailureKind.wire,
        );
      }
      if (tamper) {
        try {
          await custody.generate(
            ownerId: owner,
            entryId: 'sealed-entry',
            seedVersion: 1,
            unixSeconds: 59,
          );
          await check('tamper_no_custody', false);
        } on CustodyException catch (e) {
          await check('tamper_no_custody', e.error == CustodyError.notFound);
        }
      } else {
        await check(
          'sealed_rfc_code',
          await custody.generate(
                ownerId: owner,
                entryId: 'sealed-entry',
                seedVersion: 1,
                unixSeconds: 59,
              ) ==
              '94287082',
        );
      }
    } finally {
      await sync.finish(batch.handleId);
    }
  }
}

Future<void> run() async {
  final phase = await driver.invokeMethod<String>('config');
  final sync = SeedSyncChannel(channel);
  final id = await SeedInstallId(SeedInstallIdChannelStore(channel)).get();
  await check('install_id_valid', RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(id));
  if (phase == 'create') {
    await check(
      'fresh_owner',
      await SeedStatusChannel(channel).activeKeyId(owner) == null,
    );
    final e = await sync.enroll(owner: owner, installId: id, generation: 1);
    final key = e.keyId, pub = e.publicKey;
    await check(
      'enroll_public_only',
      pub.length == 65 && e.installId == id && e.generation == 1,
    );
    await driver.invokeMethod(
      'save',
      jsonEncode({'install': id, 'key': key, 'public': base64Encode(pub)}),
    );
    await proof(key, pub);
    try {
      await sync.enroll(owner: owner, installId: 'B' * 43, generation: 1);
      await check('install_mismatch_refused', false);
    } on SeedSyncFailure catch (e) {
      await check(
        'install_mismatch_refused',
        e.kind == SeedSyncFailureKind.installIdMismatch,
      );
    }
    final st = await sync.state(owner);
    await check('fresh_provable', st.provable && st.keyId == key);
    final batch = await sync.begin(
      owner: owner,
      deviceId: 'device',
      generation: 1,
      epoch: 0,
      entries: const [SeedBatchEntry('entry', 1, 'SHA-1', 6, 30)],
    );
    await sync.bind(
      batch.handleId,
      challenge: 'A' * 43,
      expiresAt: DateTime.now().millisecondsSinceEpoch + 60000,
    );
    final signature = await sync.signBatch(batch.handleId);
    await check(
      'typed_batch_sign',
      signature.length == 86 && batch.ephemeralPublic.length == 87,
    );
    await check(
      'typed_batch_skip',
      (await sync.skip(batch.handleId, 'entry')).isEmpty,
    );
    await sync.finish(batch.handleId);
    try {
      await sync.signBatch(batch.handleId);
      await check('typed_batch_finish', false);
    } on SeedSyncFailure catch (e) {
      await check('typed_batch_finish', e.kind == SeedSyncFailureKind.wire);
    }
    await sealedCheck(sync);
    await workspaceCheck(true);
  } else {
    final saved =
        jsonDecode((await driver.invokeMethod<String>('load'))!) as Map;
    final key = saved['key'] as String,
        pub = base64Decode(saved['public'] as String);
    await check('install_survives_restart', id == saved['install']);
    final st = await sync.state(owner);
    await check(
      'durable_key_state_after_restart',
      st.keyId == key && !st.provable,
    );
    final owners = await SeedStatusChannel(channel).owners();
    await check('durable_discovery', owners.owners.contains(owner));
    await proof(key, pub);
    await check(
      'sealed_restart_code',
      await AndroidSeedCustody(channel: channel).generate(
            ownerId: owner,
            entryId: 'sealed-entry',
            seedVersion: 1,
            unixSeconds: 59,
          ) ==
          '94287082',
    );
    await workspaceCheck(false);
    localRuntime.lock();
    await check(
      'workspace_lock_hides',
      localRuntime.snapshot == null && localRuntime.visibleCodes.isEmpty,
    );
    final state = (await call<Map>('readOwnerState', {'owner': owner}))!;
    final erased = await sync.erase(
      owner: owner,
      epoch: state['epoch'] as int,
      reason: SeedEraseReason.disable,
    );
    await check('erase_complete', erased.complete);
    try {
      await AndroidSeedCustody(channel: channel).generate(
        ownerId: owner,
        entryId: 'sealed-entry',
        seedVersion: 1,
        unixSeconds: 59,
      );
      await check('sealed_erased_unusable', false);
    } on CustodyException catch (e) {
      await check(
        'sealed_erased_unusable',
        {CustodyError.notFound, CustodyError.denied}.contains(e.error),
      );
    }

    await check(
      'erase_no_active_key',
      await SeedStatusChannel(channel).activeKeyId(owner) == null,
    );
    final after = (await call<Map>('readOwnerState', {'owner': owner}))!;
    await check(
      'shared_custody_disabled',
      after['enabled'] == false &&
          (after['epoch'] as int) > (state['epoch'] as int),
    );
    await check(
      'install_survives_erase',
      await SeedInstallId(SeedInstallIdChannelStore(channel)).get() == id,
    );
  }
  if (phase != 'create') {
    localRuntime.lock();
    await check(
      'workspace_disabled_discovery_refused',
      await workspaceAdmission
          .discover()
          .then((_) => false)
          .catchError((_) => true),
    );
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Synthetic seed host check'))),
      ),
    );
  }
  await check('phase_complete', true);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Synthetic seed host check'))),
    ),
  );
  run().catchError((Object e) async {
    await driver.invokeMethod('log', {'label': 'phase_failed', 'ok': false});
  });
}
