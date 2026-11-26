// Host-VM test of the fixture Dart entry with MOCKED engine channels (not the emulator, not the native host): proves the Dart driver logic and its log vocabulary.
// Run: flutter test tool/android-lock-prompt/fixture_main_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lock_fixture_main.dart' as fixture;

Future<List<String>> _run({
  required String action,
  required String startOutcome,
  required bool enabledAfter,
  int cancelMs = 0,
}) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final m = binding.defaultBinaryMessenger;
  final log = <String>[];
  var enabled = true;
  m.setMockMethodCallHandler(const MethodChannel('lockfx/driver'), (
    call,
  ) async {
    switch (call.method) {
      case 'config':
        return {
          'mode': 'dart',
          'action': action,
          'cancelMs': cancelMs,
          'scenario': 't',
        };
      case 'log':
        log.add('${call.arguments['name']} ${call.arguments['kv']}');
        return null;
      case 'flagPresent':
        return enabled;
    }
    return null;
  });
  m.setMockMethodCallHandler(
    const MethodChannel('app.otpanda/app-lock'),
    (call) async => call.method == 'enabled' ? enabled : null,
  );
  m.setMockMethodCallHandler(const MethodChannel('app.otpanda/lock-recovery'), (
    call,
  ) async {
    switch (call.method) {
      case 'start':
        expect(call.arguments['bearer'], 'fixture-bearer-not-a-real-token');
        if (startOutcome == 'DISABLED') enabled = enabledAfter;
        return startOutcome;
      case 'consumeUnlock':
        return true;
      case 'cancel':
        return null;
    }
    return null;
  });
  await binding.runAsync(() async {
    await fixture.main();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  return log;
}

void main() {
  testWidgets('unlock path logs outcome, consume, and an unlocked controller', (
    t,
  ) async {
    final log = await _run(
      action: 'unlock',
      startOutcome: 'UNLOCK_GRANTED',
      enabledAfter: true,
    );
    expect(
      log.any((l) => l.startsWith('outcome') && l.contains('UNLOCK_GRANTED')),
      isTrue,
      reason: '$log',
    );
    expect(
      log.any((l) => l.startsWith('consume') && l.contains('true')),
      isTrue,
    );
    expect(
      log.any(
        (l) =>
            l.startsWith('recover_done') &&
            l.contains('locked: false') &&
            l.contains('enabled: true') &&
            l.contains('busy: false'),
      ),
      isTrue,
      reason: '$log',
    );
  });
  testWidgets(
    'disable path ends with the lock off, read back through the channel',
    (t) async {
      final log = await _run(
        action: 'disable',
        startOutcome: 'DISABLED',
        enabledAfter: false,
      );
      expect(
        log.any(
          (l) =>
              l.startsWith('recover_done') &&
              l.contains('enabled: false') &&
              l.contains('locked: false'),
        ),
        isTrue,
        reason: '$log',
      );
      expect(
        log.any((l) => l.startsWith('app_lock_enabled') && l.contains('false')),
        isTrue,
      );
    },
  );
  testWidgets('user cancel leaves the lock on with no error', (t) async {
    final log = await _run(
      action: 'unlock',
      startOutcome: 'USER_CANCELLED',
      enabledAfter: true,
    );
    expect(
      log.any(
        (l) =>
            l.startsWith('recover_done') &&
            l.contains('locked: true') &&
            l.contains('enabled: true') &&
            l.contains('error: none'),
      ),
      isTrue,
      reason: '$log',
    );
  });
}
