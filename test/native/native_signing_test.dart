import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_signing.dart';

Uint8List hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(
    File('test/fixtures/native-vector.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final cases = v['cases'] as Map<String, dynamic>;

  for (final purpose in NativePurpose.values) {
    final c = cases[purpose.name] as Map<String, dynamic>;
    test('${purpose.name}: message bytes match the API vector', () {
      final m = nativeMessage(
        purpose: purpose,
        deviceId: c['device_id'] as String,
        nonce: c['nonce'] as String,
        expiresAt: c['expires_at'] as int,
      );
      expect(toHex(m), c['message_hex']);
      expect(utf8.decode(m), c['message_utf8']);
      expect(utf8.decode(m).endsWith('\n'), isFalse);
      expect(utf8.decode(m).split('\n'), hasLength(5));
    });

    test('${purpose.name}: Keystore DER converts to the server raw r||s', () {
      final raw = ecdsaDerToRaw(hex(c['signature_der_hex'] as String));
      expect(raw, hasLength(64));
      expect(base64UrlNoPad(raw), c['signature_raw']);
    });
  }

  test('DER parser rejects malformed input', () {
    expect(() => ecdsaDerToRaw(Uint8List(0)), throwsFormatException);
    expect(
      () => ecdsaDerToRaw(hex('3006020101020101ff')),
      throwsFormatException,
    );
    expect(() => ecdsaDerToRaw(hex('3145022100')), throwsFormatException);
    // integer of 33 non-zero bytes is too large
    final big = hex('30470221${'01' * 33}0201');
    expect(() => ecdsaDerToRaw(big), throwsFormatException);
  });

  test('renewal key encodes as an uncompressed point', () {
    final pub = base64UrlDecodeNoPad(v['public_key'] as String);
    expect(pub, hasLength(65));
    expect(pub.first, 0x04);
    expect(
      encodeRenewalKey(pub.sublist(1, 33), pub.sublist(33)),
      v['public_key'],
    );
  });
}
