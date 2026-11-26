import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_local_lock_recovery.dart';
import 'package:otpanda_client/native/native_app_lock.dart';

class Platform implements LocalLockPlatform, LocalRecoveryPlatform {
  bool saved = true, grant = true, failAfterDisable = false;
  String outcome = 'UNLOCK_GRANTED';
  int calls = 0, cancellations = 0;
  Future<void> Function()? duringStart;
  @override
  Future<bool> enabled() async => saved;
  @override
  Future<bool> verify() async => false;
  @override
  Future<void> setEnabled(bool v) async {
    saved = v;
  }

  @override
  Future<String> start(String intent, String bearer) async {
    calls++;
    await duringStart?.call();
    if (intent == 'local-lock-disable') saved = false;
    if (failAfterDisable) throw StateError('lost channel response');
    return outcome;
  }

  @override
  Future<bool> consumeUnlock() async {
    final result = grant;
    grant = false;
    return result;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
  }
}

void main() {
  Future<LocalLockController> controller(Platform p) async {
    final c = LocalLockController(p);
    await c.load();
    c.recovery = NativeLocalLockRecovery(
      platform: p,
      bearer: () async => 'synthetic-access',
    );
    return c;
  }

  test('native owns disable, unlock grant is consumed once', () async {
    final p = Platform(), c = await controller(Platform());
    c.dispose();
    final once = await controller(p);
    await once.recover(disable: false);
    expect(once.locked, false);
    expect(p.saved, true);
    expect(p.grant, false);
    once.sessionChanged();
    await once.recover(disable: false);
    expect(once.locked, true);
    once.dispose();
    final d = Platform()..outcome = 'DISABLED', disabled = await controller(d);
    await disabled.recover(disable: true);
    expect(disabled.enabled, false);
    expect(disabled.locked, false);
    expect(d.saved, false);
    disabled.dispose();
  });
  test(
    'unavailable and canceled attempts keep lock, no resume grant',
    () async {
      for (final outcome in [
        'NETWORK_UNAVAILABLE',
        'ABORTED',
        'USER_CANCELLED',
        'OUTCOME_UNKNOWN',
        'UNAUTHORIZED',
      ]) {
        final p = Platform()..outcome = outcome, c = await controller(p);
        await c.recover(disable: false);
        c.resume();
        expect(c.locked, true);
        expect(c.enabled, true);
        c.dispose();
      }
    },
  );
  test('session change during native attempt rejects late result', () async {
    final p = Platform(), c = await controller(p);
    p.duringStart = () async {
      c.sessionChanged();
    };
    await c.recover(disable: false);
    c.resume();
    expect(c.locked, true);
    expect(p.cancellations, greaterThan(0));
    c.dispose();
  });
  test('failed disable answer re-reads durable native truth', () async {
    final p = Platform()..failAfterDisable = true, c = await controller(p);
    await c.recover(disable: true);
    expect(c.enabled, false);
    expect(c.locked, false);
    expect(c.error, isNull);
    c.dispose();
  });
}
