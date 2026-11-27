// Debug-only qualification target, never part of the app build. Drives the real AndroidImportPicker against the real
// ImportPickerHost and the real system picker. Synthetic documents only. Logs fixed labels and booleans, never content.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:otpanda_client/transfer/android_import_picker.dart';

const _driver = MethodChannel('pickfx/driver');

Future<void> _log(String label, bool ok) =>
    _driver.invokeMethod<void>('log', {'label': label, 'ok': ok});
Future<void> _mark(String label) =>
    _driver.invokeMethod<void>('mark', {'label': label});
Future<void> _phase(String phase) =>
    _driver.invokeMethod<void>('setPhase', {'phase': phase});

Future<ImportPickerError?> _error(Future<String?> pending) async {
  try {
    await pending;
    return null;
  } on ImportPickerException catch (e) {
    return e.error;
  }
}

Future<void> _normal(AndroidImportPicker p) async {
  await _mark('pick_1');
  final t1 = await p.pick();
  await _log('normal_first_text', t1 == 'synthetic-a');
  final stops = await _driver.invokeMethod<int>('stopCount') ?? 0;
  await _log('normal_backgrounded', stops >= 1);
  await _mark('pick_2');
  final second = p.pick();
  final busy = await _error(p.pick());
  await _log('normal_busy_pending', busy == ImportPickerError.busy);
  await _log('normal_second_text', await second == 'synthetic-b');
  await _mark('pick_3');
  await _log('normal_cancel_null', await p.pick() == null);
  await _log('phase_complete', true);
}

Future<void> _errors(AndroidImportPicker p) async {
  await _mark('pick_1');
  await _log(
    'errors_not_text',
    await _error(p.pick()) == ImportPickerError.notText,
  );
  await _mark('pick_2');
  await _log(
    'errors_too_large',
    await _error(p.pick()) == ImportPickerError.tooLarge,
  );
  await _log('phase_complete', true);
}

/// Rotation or recreate() with the picker open. If the engine survives, the result must arrive once. If the engine was
/// retired, the new Dart run finds phase "picking" and the old selection must never have been opened.
Future<void> _rotation(AndroidImportPicker p, String phase) async {
  if (phase == 'picking') {
    await _log('rotation_recreated_dropped', true);
    await _log('phase_complete', true);
    return;
  }
  await _phase('picking');
  await _mark('picker_open');
  final t = await p.pick();
  await _phase('done');
  await _log('rotation_text', t == 'synthetic-a');
  await _log('phase_complete', true);
}

/// Caller engine (or whole process) is gone while the system picker is alive. The old selection arrives at a new engine and
/// must never be opened or handed to a later request.
Future<void> _stale(AndroidImportPicker p, String phase) async {
  if (phase == 'start') {
    await _phase('picking');
    await _mark('old_picker_open');
    final t = await p.pick();
    // Only reachable if this engine was NOT retired, which means the scenario did not do its job.
    await _log('stale_old_engine_gone', false);
    if (t != null) await _log('stale_unexpected_delivery', false);
    return;
  }
  await _log('stale_old_engine_gone', phase == 'picking');
  await Future<void>.delayed(const Duration(seconds: 4));
  await _phase('second');
  await _mark('pick_2');
  final t = await p.pick();
  await _log('stale_second_text', t == 'synthetic-b');
  await _log('phase_complete', true);
}

Future<void> _run() async {
  try {
    final cfg = Map<String, Object?>.from(
      await _driver.invokeMethod<Map>('config') as Map,
    );
    final scenario = cfg['scenario'] as String;
    final phase = cfg['phase'] as String;
    final p = AndroidImportPicker();
    switch (scenario) {
      case 'normal':
        await _normal(p);
      case 'errors':
        await _errors(p);
      case 'rotation' || 'recreate':
        await _rotation(p, phase);
      case 'stale_recreate' || 'stale_kill':
        await _stale(p, phase);
      default:
        await _log('unknown_scenario', false);
    }
  } catch (_) {
    await _log('fixture_exception', false);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _App());
}

class _App extends StatefulWidget {
  const _App();
  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  Widget build(BuildContext context) => const MaterialApp(
    home: Scaffold(body: Center(child: Text('Synthetic picker fixture check'))),
  );
}
