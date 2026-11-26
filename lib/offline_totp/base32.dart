import 'dart:typed_data';

import 'otp_account.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// RFC 4648 base32, case-insensitive, padding optional (only trailing '=').
Uint8List decodeBase32(String input) {
  var s = input;
  while (s.endsWith('=')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty || s.length > 208) {
    throw const OtpFormatException(OtpFormatError.badSecret);
  }
  var bits = 0, value = 0;
  final out = <int>[];
  for (final u in s.toUpperCase().codeUnits) {
    final i = _alphabet.indexOf(String.fromCharCode(u));
    if (i < 0) throw const OtpFormatException(OtpFormatError.badSecret);
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((value >> bits) & 0xff);
      value &= (1 << bits) - 1;
    }
  }
  // Leftover bits must be zero padding, never a hidden extra byte.
  if (value != 0) throw const OtpFormatException(OtpFormatError.badSecret);
  return Uint8List.fromList(out);
}

String encodeBase32(Uint8List bytes) {
  final b = StringBuffer();
  var bits = 0, value = 0;
  for (final byte in bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      b.write(_alphabet[(value >> bits) & 31]);
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) b.write(_alphabet[(value << (5 - bits)) & 31]);
  return b.toString();
}
