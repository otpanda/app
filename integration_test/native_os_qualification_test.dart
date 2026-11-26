// UNRUN on a device by its author: needs a real Android emulator or device.
// Real AndroidKeystore and real Credential Manager through the app's own
// channel adapters. No server and no account are involved, and the production
// transport is untouched. Run: tool/android-os-qualify.sh
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/native/native_signing.dart';

import 'p256_verify.dart';

// Set by tool/android-os-qualify.sh, which presses BACK on the system sheet.
const _sheet = bool.fromEnvironment('OS_SHEET');

Uint8List _msg(String nonce) => nativeMessage(
  purpose: NativePurpose.renew,
  deviceId: 'qualification-device',
  nonce: nonce,
  expiresAt: 4102444800000,
);

bool _same(Uint8List a, Uint8List b) =>
    a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final ks = AndroidKeystoreAdapter();
  final rec = AndroidRecognitionStore();

  setUp(() async {
    await ks.deleteKey();
    await rec.clear();
  });
  tearDownAll(() async {
    await ks.deleteKey();
    await rec.clear();
  });

  group('Keystore renewal key', () {
    test('ensureKey is a stable P-256 point and the signature verifies', () async {
      final a = await ks.ensureKey();
      expect(a.length, 65);
      expect(a[0], 4);
      expect(_same(a, await ks.ensureKey()), isTrue, reason: 'never replaces a valid key');
      final m = _msg('n1');
      final sig = await ks.signDer(m);
      expect(verifyP256Der(a, m, sig), isTrue);
      // Raw r||s form the server takes.
      expect(ecdsaDerToRaw(sig).length, 64);
      // Negative controls: verifier is not vacuous.
      expect(verifyP256Der(a, _msg('n2'), sig), isFalse);
      final tampered = Uint8List.fromList(sig)..[sig.length - 1] ^= 1;
      expect(verifyP256Der(a, m, tampered), isFalse);
    });

    test('pending key: discard keeps the active key', () async {
      final active = await ks.ensureKey();
      final pending = await ks.beginNewKey();
      expect(await ks.hasPendingKey(), isTrue);
      expect(_same(active, pending), isFalse);
      final m = _msg('p1');
      expect(verifyP256Der(pending, m, await ks.signDer(m, pending: true)), isTrue);
      expect(verifyP256Der(active, m, await ks.signDer(m)), isTrue);
      // Signed by one key does not verify under the other.
      expect(verifyP256Der(pending, m, await ks.signDer(m)), isFalse);
      await ks.discardNewKey();
      expect(await ks.hasPendingKey(), isFalse);
      expect(_same(active, await ks.ensureKey()), isTrue);
    });

    test('pending key: commit replaces the active key', () async {
      final old = await ks.ensureKey();
      final next = await ks.beginNewKey();
      await ks.commitNewKey();
      expect(await ks.hasPendingKey(), isFalse);
      final now = await ks.ensureKey();
      expect(_same(now, next), isTrue);
      expect(_same(now, old), isFalse);
      final m = _msg('c1');
      expect(verifyP256Der(now, m, await ks.signDer(m)), isTrue);
      expect(verifyP256Der(old, m, await ks.signDer(m)), isFalse);
    });

    test('deleteKey then ensureKey makes a different key', () async {
      final a = await ks.ensureKey();
      await ks.deleteKey();
      final b = await ks.ensureKey();
      expect(_same(a, b), isFalse);
    });
  });

  group('Recognition store (Keystore AES-GCM)', () {
    test('write, read, overwrite, clear', () async {
      expect(await rec.read(), isNull);
      await rec.write('otpda_synthetic_value_one');
      expect(await rec.read(), 'otpda_synthetic_value_one');
      await rec.write('otpda_synthetic_value_two');
      expect(await rec.read(), 'otpda_synthetic_value_two');
      await rec.clear();
      expect(await rec.read(), isNull);
    });
  });

  group('Credential Manager', () {
    final src = AndroidPasskeySource();

    test('availability is answered without crashing', () async {
      await src.probe();
      // Prints the real answer for the run log. It is not asserted either way,
      // because it depends on the image (API 34+ is always true).
      // ignore: avoid_print
      print('PASSKEY_AVAILABLE=${src.available}');
      expect(src.available, isA<bool>());
    });

    test('an empty request is refused by the host, not sent to the OS', () async {
      await src.probe();
      await expectLater(
        src.get(''),
        throwsA(isA<PasskeyException>().having((e) => e.code, 'code', 'bad_args')),
      );
    });

    test('sheet cancel returns null (needs OS_SHEET and the BACK driver)', () async {
      await src.probe();
      if (!src.available) return;
      final challenge = base64Url.encode(List<int>.filled(32, 7)).replaceAll('=', '');
      final request = jsonEncode({
        'rpId': 'otpanda.github.io',
        'challenge': challenge,
        'userVerification': 'required',
        'timeout': 60000,
        'allowCredentials': <Map<String, String>>[],
      });
      // With no credential the system shows its sheet or an error. A user
      // cancel is null, and a provider with nothing to offer is a typed
      // PasskeyException. Both are acceptable. A hang or crash is not.
      Object? outcome = 'pending';
      try {
        outcome = await src.get(request).timeout(const Duration(seconds: 45));
      } on PasskeyException catch (e) {
        outcome = e;
      }
      // ignore: avoid_print
      print('SHEET_OUTCOME=$outcome');
      if (_sheet) {
        expect(outcome, anyOf(isNull, isA<PasskeyException>()));
      } else {
        expect(outcome, isNot('pending'));
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
