import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'otp_account.dart';

/// Reference RFC 6238 calculator for custody adapters that hold the seed in
/// process memory (desktop). Digits 6 to 8, period 1..86400. It does not
/// replace a non-extractable platform HMAC where one exists. Dart cannot
/// guarantee that [seed] or intermediate buffers are wiped.
String computeTotp({
  required Uint8List seed,
  required OtpAlgorithm algorithm,
  required int digits,
  required int period,
  required int unixSeconds,
}) {
  if (digits < 6 || digits > 8 || period < 1 || period > 86400) {
    throw RangeError('digits 6..8 and period 1..86400 required');
  }
  if (unixSeconds < 0 || unixSeconds > 9007199254740991) {
    throw RangeError('unixSeconds out of range');
  }
  final counter = unixSeconds ~/ period;
  // 8-byte big-endian counter without 64-bit shifts, so the VM and compiled
  // JS agree.
  final msg = ByteData(8)
    ..setUint32(0, counter ~/ 4294967296)
    ..setUint32(4, counter % 4294967296);
  final hash = switch (algorithm) {
    OtpAlgorithm.sha1 => sha1,
    OtpAlgorithm.sha256 => sha256,
    OtpAlgorithm.sha512 => sha512,
  };
  final mac = Hmac(hash, seed).convert(msg.buffer.asUint8List()).bytes;
  final o = mac.last & 0x0f;
  final bin =
      ((mac[o] & 0x7f) << 24) |
      (mac[o + 1] << 16) |
      (mac[o + 2] << 8) |
      mac[o + 3];
  var mod = 1;
  for (var i = 0; i < digits; i++) {
    mod *= 10;
  }
  return (bin % mod).toString().padLeft(digits, '0');
}
