import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_local_lock_recovery.dart';
import 'package:otpanda_client/native/native_app_lock.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/session_contract.dart';

class Keys implements PasskeyAssertionSource {
  @override
  bool available = true;
  bool cancel = false;
  Future<void> Function()? onGet;
  @override
  Future<String?> get(String request) async {
    await onGet?.call();
    return cancel
        ? null
        : jsonEncode({
            'type': 'public-key',
            'id': 'id',
            'rawId': 'id',
            'response': {
              'clientDataJSON': 'a',
              'authenticatorData': 'a',
              'signature': 'a',
              'userHandle': 'owner',
            },
          });
  }
}

class Platform implements LocalLockPlatform, PasskeyDisablePlatform {
  bool saved = true;
  int disables = 0;
  @override
  Future<bool> enabled() async => saved;
  @override
  Future<bool> verify() async => false;
  @override
  Future<void> setEnabled(bool v) async {
    saved = v;
  }

  @override
  Future<void> disableAfterPasskey() async {
    disables++;
    saved = false;
  }
}

void main() {
  test('fresh exact-intent response unlocks once without disabling and disable is separate', () async {
    for (final disable in [false, true]) {
      final keys = Keys(), p = Platform(), calls = <Map<String, dynamic>>[];
      final c = LocalLockController(p);
      await c.load();
      c.recovery = NativeLocalLockRecovery(
        passkeys: keys,
        deviceId: () => 'device',
        now: () => 1000,
        post: (path, body) async {
          final v = jsonDecode(body) as Map<String, dynamic>;
          calls.add(v);
          if (path.endsWith('begin')) {
            return SessionResponse(
              200,
              jsonEncode({
                'token': 'otpda_${'a' * 55}',
                'expiresAt': 121000,
                'options': {
                  'rpId': 'otpanda.github.io',
                  'userVerification': 'required',
                  'challenge': 'a' * 43,
                  'allowCredentials': [],
                },
              }),
            );
          }
          return SessionResponse(
            200,
            jsonEncode({
              'intent': v['intent'],
              'lockGeneration': v['lockGeneration'],
              'deviceId': 'device',
              'generation': 3,
            }),
          );
        },
      );
      await c.recover(disable: disable);
      expect(c.locked, false);
      expect(c.enabled, !disable);
      expect(p.disables, disable ? 1 : 0);
      expect(calls.length, 2);
      expect(
        calls[0]['intent'],
        disable ? 'local-lock-disable' : 'local-unlock-once',
      );
      c.dispose();
    }
  });
  test(
    'cancellation, wrong echoed intent and device change stay locked',
    () async {
      for (final mode in ['cancel', 'intent', 'device']) {
        final keys = Keys()..cancel = mode == 'cancel';
        final p = Platform(), c = LocalLockController(p);
        await c.load();
        var device = 'device';
        if (mode == 'device') {
          keys.onGet = () async {
            device = 'other';
          };
        }
        c.recovery = NativeLocalLockRecovery(
          passkeys: keys,
          deviceId: () => device,
          now: () => 1000,
          post: (path, body) async {
            final v = jsonDecode(body);
            return SessionResponse(
              200,
              jsonEncode(
                path.endsWith('begin')
                    ? {
                        'token': 'otpda_${'a' * 55}',
                        'expiresAt': 121000,
                        'options': {
                          'rpId': 'otpanda.github.io',
                          'userVerification': 'required',
                          'challenge': 'a' * 43,
                          'allowCredentials': [],
                        },
                      }
                    : {
                        'intent': 'local-lock-disable',
                        'lockGeneration': v['lockGeneration'],
                        'deviceId': 'device',
                        'generation': 3,
                      },
              ),
            );
          },
        );
        await c.recover(disable: false);
        expect(c.locked, true);
        expect(p.disables, 0);
        c.dispose();
      }
    },
  );
}
