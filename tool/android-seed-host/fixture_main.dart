// Debug-only synthetic entrypoint, no network and no production session.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/offline_totp/seed_install_id.dart';
import 'package:otpanda_client/offline_totp/seed_install_id_channel.dart';
import 'package:otpanda_client/offline_totp/seed_status_channel.dart';

const channel = MethodChannel('app.otpanda/seed-custody');
const driver = MethodChannel('seedfx/driver');
const owner = 'fixture-owner';
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

Future<void> run() async {
  final phase = await driver.invokeMethod<String>('config');
  final id = await SeedInstallId(SeedInstallIdChannelStore(channel)).get();
  await check('install_id_valid', RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(id));
  if (phase == 'create') {
    await check(
      'fresh_owner',
      await SeedStatusChannel(channel).activeKeyId(owner) == null,
    );
    final e = (await call<Map>('syncEnroll', {
      'owner': owner,
      'installId': id,
      'generation': 1,
    }))!;
    final key = e['keyId'] as String, pub = e['publicKey'] as Uint8List;
    await check(
      'enroll_public_only',
      e.keys.toSet().difference({
            'keyId',
            'publicKey',
            'generation',
            'installId',
          }).isEmpty &&
          pub.length == 65 &&
          e['installId'] == id,
    );
    await driver.invokeMethod(
      'save',
      jsonEncode({'install': id, 'key': key, 'public': base64Encode(pub)}),
    );
    await proof(key, pub);
    await refuses(
      'install_mismatch_refused',
      'syncEnroll',
      {'owner': owner, 'installId': 'B' * 43, 'generation': 1},
      {'INSTALL_ID_MISMATCH'},
    );
    final st = (await call<Map>('syncEnrollmentState', {'owner': owner}))!;
    await check('fresh_provable', st['provable'] == true && st['keyId'] == key);
  } else {
    final saved =
        jsonDecode((await driver.invokeMethod<String>('load'))!) as Map;
    final key = saved['key'] as String,
        pub = base64Decode(saved['public'] as String);
    await check('install_survives_restart', id == saved['install']);
    final st = (await call<Map>('syncEnrollmentState', {'owner': owner}))!;
    await check(
      'durable_key_state_after_restart',
      st['keyId'] == key && st['provable'] == false,
    );
    final owners = await SeedStatusChannel(channel).owners();
    await check('durable_discovery', owners.owners.contains(owner));
    await proof(key, pub);
    final state = (await call<Map>('readOwnerState', {'owner': owner}))!;
    final erased = (await call<Map>('syncErase', {
      'owner': owner,
      'epoch': state['epoch'],
      'trigger': 'disable',
    }))!;
    await check(
      'erase_complete',
      erased['keyDeleted'] == true && erased['seedsPurged'] == true,
    );
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
