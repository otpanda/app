// DEBUG fixture entrypoint only: build with `flutter build apk --debug --flavor google -t tool/android-lock-prompt/lock_fixture_main.dart`.
// Never part of a release build (release builds lib/main.dart). It reads the debug-only channel "lockfx/driver", which only the debug fixture Activity registers.
//  - mode loopback (or no driver): runs no app code, so only the native host under test runs.
//  - mode dart: drives the REAL LocalLockController + NativeLocalLockRecovery + ChannelLocalRecovery/ChannelLocalLock over the REAL engine MethodChannels
//    ('app.otpanda/lock-recovery', 'app.otpanda/app-lock') into the real native hosts. The bearer is a fixed non-secret placeholder the fake API checks.
//    It does not tap the lock screen's buttons, does not use the real session/bearer path (NativeRoot, NativeSession), and uses no network.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/native/native_app_lock.dart';
import 'package:otpanda_client/native/native_local_lock_recovery.dart';

const _driver = MethodChannel('lockfx/driver');

Future<void> _log(String name, [Map<String, Object?> kv = const {}]) async {
  try {
    await _driver.invokeMethod('log', {
      'name': name,
      'kv': kv.map((k, v) => MapEntry(k, '$v')),
    });
  } catch (_) {}
}

/// Logs around the real channel adapter. It forwards every call unchanged.
class _LoggingRecovery implements LocalRecoveryPlatform {
  final _inner = ChannelLocalRecovery();
  @override
  Future<String> start(String intent, String bearer) async {
    await _log('channel_start', {'intent': intent});
    final r = await _inner.start(intent, bearer);
    await _log('outcome', {'value': r});
    return r;
  }

  @override
  Future<void> cancel() async {
    await _log('channel_cancel');
    await _inner.cancel();
  }

  @override
  Future<bool> consumeUnlock() async {
    final r = await _inner.consumeUnlock();
    await _log('consume', {'value': r});
    return r;
  }
}

class _Life with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log('lifecycle', {'state': state.name});
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Map<dynamic, dynamic>? cfg;
  try {
    cfg = await _driver.invokeMethod<Map<dynamic, dynamic>>('config');
  } catch (_) {
    cfg = null;
  }
  if (cfg == null || cfg['mode'] != 'dart') {
    runApp(const SizedBox.shrink());
    return;
  }
  WidgetsBinding.instance.addObserver(_Life());
  final c = LocalLockController(ChannelLocalLock());
  c.recovery = NativeLocalLockRecovery(
    platform: _LoggingRecovery(),
    bearer: () async => 'fixture-bearer-not-a-real-token',
  );
  String last = '';
  void state(String tag) {
    final s =
        'enabled=${c.enabled} locked=${c.locked} busy=${c.busy} error=${c.error == null ? 'none' : 'set'}';
    if (s != last || tag != 'listen') {
      last = s;
      _log('state', {
        'tag': tag,
        'enabled': c.enabled,
        'locked': c.locked,
        'busy': c.busy,
        'error': c.error == null ? 'none' : 'set',
      });
    }
  }

  c.addListener(() => state('listen'));
  runApp(
    MaterialApp(
      home: NativeAppLock(
        controller: c,
        child: const Text('otpanda lock fixture (synthetic)'),
      ),
    ),
  );
  for (var i = 0; i < 100 && !c.ready; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  state('loaded');
  await _log('loaded', {
    'ready': c.ready,
    'enabled': c.enabled,
    'locked': c.locked,
  });
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  final cancelMs = (cfg['cancelMs'] as int?) ?? 0;
  if (cancelMs > 0) {
    Timer(Duration(milliseconds: cancelMs), () async {
      await _log('cancel_called');
      c.sessionChanged(); // the real controller's session-change path -> NativeLocalLockRecovery.cancel() -> the real channel
    });
  }
  final disable = cfg['action'] == 'disable';
  await _log('recover_start', {'disable': disable});
  await c.recover(disable: disable);
  state('recover_done');
  await _log('recover_done', {
    'enabled': c.enabled,
    'locked': c.locked,
    'busy': c.busy,
    'error': c.error == null ? 'none' : 'set',
  });
  try {
    await _log('app_lock_enabled', {
      'value': await ChannelLocalLock().enabled(),
    }); // the real AppLockHost over the real channel
  } catch (_) {
    await _log('app_lock_enabled', {'value': 'error'});
  }
  try {
    await _driver.invokeMethod('flagPresent');
  } catch (_) {}
}
