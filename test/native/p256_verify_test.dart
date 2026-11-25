import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/p256_verify.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
]);

/// Positive and negative controls for the verifier the emulator test relies
/// on. The vector was produced by OpenSSL, independent of Dart and Android.
void main() {
  final v = jsonDecode(File('test/native/p256_vector.json').readAsStringSync())
      as Map<String, dynamic>;
  final point = hex(v['point'] as String);
  final msg = hex(v['message'] as String);
  final der = hex(v['der'] as String);

  test('accepts a real OpenSSL signature', () {
    expect(verifyP256Der(point, msg, der), isTrue);
  });
  test('rejects a changed message', () {
    final bad = Uint8List.fromList(msg)..[0] ^= 1;
    expect(verifyP256Der(point, bad, der), isFalse);
  });
  test('rejects a changed signature and a different key', () {
    final badSig = Uint8List.fromList(der)..[der.length - 1] ^= 1;
    expect(verifyP256Der(point, msg, badSig), isFalse);
    final badKey = Uint8List.fromList(point)..[64] ^= 1;
    expect(verifyP256Der(badKey, msg, der), isFalse);
  });
}
