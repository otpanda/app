// DEBUG-ONLY CANDIDATE, NOT COMPILED OR RUN (no Flutter SDK in the authoring sandbox). Drop-in sibling of tool/android-seed-host/fixture_main.dart (app3502 tree).
// Replaces the presealed SyntheticSeedSealer with the real chain: production SeedEnrollmentCoordinator + SeedEnrollmentHttp + SeedPasskeyStepUp, production
// SeedSyncCoordinator + SeedSyncHttp, production SeedSyncChannel/AndroidSeedCustody/AndroidWrappingKeyStore/NativeWorkspaceAdmission, against
// tool/seed-sync-loopback/server.mjs (real createIdentityRuntime) at http://10.0.2.2:8787 on a disposable emulator.
// Debug seams, all under tool/ and never under lib/: (1) LoopbackPasskeySource implements PasskeyAssertionSource and asks the host authenticator to sign the
// request JSON that production passkeyRequestJson already validated. It is NOT the OS credential prompt. (2) a DevicePost that sends the loopback bearer over HTTP.
// (3) a SeedStatusTransport pointing at the loopback (production SeedStatusHttp has the production origin hard-coded, which is correct and unchanged).
// Needs: debug-only network_security_config allowing cleartext to 10.0.2.2, and the host started with the debug APK's SHA-256 so the assertion origin equals the real apk-key-hash.
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/native/native_workspace_admission.dart';
import 'package:otpanda_client/offline_totp/android_seed_custody.dart';
import 'package:otpanda_client/offline_totp/seed_enrollment_coordinator.dart';
import 'package:otpanda_client/offline_totp/seed_enrollment_http.dart';
import 'package:otpanda_client/offline_totp/seed_install_id.dart';
import 'package:otpanda_client/offline_totp/seed_install_id_channel.dart';
import 'package:otpanda_client/offline_totp/seed_status_channel.dart';
import 'package:otpanda_client/offline_totp/seed_status_coordinator.dart';
import 'package:otpanda_client/offline_totp/seed_sync_http.dart';
import 'package:otpanda_client/offline_totp/seed_sync_channel.dart';
import 'package:otpanda_client/offline_totp/seed_sync_coordinator.dart';

const channel = MethodChannel('app.otpanda/seed-custody');
const driver = MethodChannel('seedfx/driver');
const owner = 'fixture-owner';
final loopback = Uri.parse(
  const String.fromEnvironment(
    'LOOPBACK_BASE',
    defaultValue: 'http://127.0.0.1:8787',
  ),
);

Future<Map<String, dynamic>> _json(
  String method,
  String path, [
  String? body,
  String? bearer,
]) async {
  final c = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final r = await (method == 'GET'
        ? c.getUrl(loopback.replace(path: path))
        : c.postUrl(loopback.replace(path: path)));
    if (bearer != null) r.headers.set('authorization', 'Bearer $bearer');
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.add(utf8.encode(body));
    }
    final res = await r.close();
    final text = await utf8.decodeStream(res);
    return {'status': res.statusCode, 'text': text};
  } finally {
    c.close(force: true);
  }
}

/// Synthetic authenticator over loopback. Same interface the production step-up consumes.
final class LoopbackPasskeySource implements PasskeyAssertionSource {
  @override
  bool get available => true;
  @override
  Future<String?> get(String requestJson) async {
    final r = await _json('POST', '/__loopback/assert', requestJson);
    return r['status'] == 200 ? r['text'] as String : null;
  }
}

final class LoopbackStatus implements SeedStatusTransport {
  @override
  Future<SeedStatusResponse> post(String path, Map<String, Object> body) async {
    final r = await _json('POST', path, jsonEncode(body));
    return SeedStatusResponse(r['status'] as int, r['text'] as String);
  }
}

Future<void> check(String label, bool ok) async {
  await driver.invokeMethod('log', {'label': label, 'ok': ok});
  if (!ok) throw StateError(label);
}

Future<void> run() async {
  final phase = await driver.invokeMethod<String>('config');
  final native = SeedSyncChannel(channel),
      status = SeedStatusChannel(channel),
      custody = AndroidSeedCustody(channel: channel);
  final session = jsonDecode(
    (await _json('POST', '/__loopback/session'))['text'] as String,
  ) as Map<String, dynamic>;
  final bearer = session['access'] as String;
  Future<({int status, Map<String, dynamic>? body})> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final r = await _json('POST', path, jsonEncode(body), bearer);
    // Fixed diagnostic labels and status only, never response bodies or tokens.
    final op = path.split('/').last.replaceAll('-', '_');
    await driver.invokeMethod('log', {
      'label': 'http_${op}_ok',
      'ok': r['status'] == 200,
    });
    Map<String, dynamic>? b;
    try {
      final j = jsonDecode(r['text'] as String);
      b = j is Map<String, dynamic> ? j : null;
    } catch (_) {}
    return (status: r['status'] as int, body: b);
  }

  final transport = LoopbackStatus();
  final api = SeedEnrollmentHttp(
    post: post,
    statusTransport: transport,
    signStatus:
        ({
          required owner,
          required keyId,
          required challenge,
          required expiresAt,
        }) => status.signStatus(
          owner: owner,
          askedKeyId: keyId,
          challenge: challenge,
          expiresAt: expiresAt,
        ),
  );
  final enrollment = SeedEnrollmentCoordinator(
    native: SeedEnrollmentNativeAdapter(native),
    api: api,
    passkey: SeedPasskeyStepUp(LoopbackPasskeySource()),
    isCurrent: (o) async => o == owner,
  );
  final pull = SeedSyncCoordinator(
    api: SeedSyncHttp(post: post),
    native: SeedSyncNativeAdapter(native),
    custody: custody,
    current: (o) async => o == owner,
  );
  final id = await SeedInstallId(SeedInstallIdChannelStore(channel)).get();
  final admission = NativeWorkspaceAdmission();
  if (phase == 'create') {
    // Production admission first: it is what enables shared custody for the owner (primary's root owns the verified-owner + unlock gate in front of this call).
    final admitted = await admission.admit(owner, 0);
    await check('admission_created', admitted.create);
    final state = await custody.readOwnerState(owner);
    await check('custody_enabled_by_admission', state.enabled);
    final e = await enrollment.run(owner: owner, installId: id);
    await driver.invokeMethod('log', {
      'label':
          'enroll_outcome_${e.outcome.name.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}')}',
      'ok': true,
    });
    await check('enroll_confirmed', e.outcome == SeedEnrollOutcome.confirmed);
    final srv = jsonDecode(
      (await _json('GET', '/__loopback/state'))['text'] as String,
    ) as Map<String, dynamic>;
    await check(
      'server_one_active_key',
      (srv['keys'] as List).length == 1 &&
          (srv['assertionsSigned'] as int) == 1,
    );
    final after = await custody.readOwnerState(owner);
    final r = await pull.sync(
      SeedSyncScope(
        owner: owner,
        installId: id,
        epoch: after.epoch,
        deviceId: session['deviceId'] as String,
      ),
    );
    await check('pull_synced', r.outcome == SeedSyncOutcome.synced);
    await check(
      'rfc_code_from_real_download',
      await custody.generate(
            ownerId: owner,
            entryId: 'sealed-entry',
            seedVersion: (srv['seeds'] as List).first['seed_version'] as int,
            unixSeconds: 59,
          ) ==
          '94287082',
    );
    await driver.invokeMethod(
      'save',
      jsonEncode({
        'install': id,
        'key': e.keyId,
        'version': (srv['seeds'] as List).first['seed_version'],
      }),
    );
  } else {
    final saved =
        jsonDecode((await driver.invokeMethod<String>('load'))!) as Map;
    await check('install_survives_restart', id == saved['install']);
    await check(
      'code_after_restart',
      await custody.generate(
            ownerId: owner,
            entryId: 'sealed-entry',
            seedVersion: saved['version'] as int,
            unixSeconds: 59,
          ) ==
          '94287082',
    );
    final st = await api.keyStatus(owner: owner, keyId: saved['key'] as String);
    await check(
      'server_key_active_by_signed_status',
      st == SeedServerKeyState.active,
    );
    final again = await enrollment.run(owner: owner, installId: id);
    await check(
      'enroll_already_confirmed_no_network',
      again.outcome == SeedEnrollOutcome.alreadyConfirmed,
    );
  }
  await check('phase_complete', true);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Synthetic loopback seed host check')),
      ),
    ),
  );
  run().catchError((Object e) async {
    await driver.invokeMethod('log', {'label': 'phase_failed', 'ok': false});
  });
}
