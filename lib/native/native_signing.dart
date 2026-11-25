import 'dart:convert';
import 'dart:typed_data';

/// What the device signs for killed-app renewal and logout. Authoritative
/// source: nativeMessage() in the API's src/native-sessions.js and the
/// cross-language vector in test/fixtures/native-vector.json. Exactly five
/// lines joined by LF, UTF-8, no trailing newline.
enum NativePurpose {
  renew('POST /auth/native/renew'),
  logout('POST /auth/native/logout');

  const NativePurpose(this.endpoint);
  final String endpoint;
}

const nativeDomain = 'otpanda-native-v1';

Uint8List nativeMessage({
  required NativePurpose purpose,
  required String deviceId,
  required String nonce,
  required int expiresAt,
}) => Uint8List.fromList(
  utf8.encode(
    [nativeDomain, purpose.endpoint, deviceId, nonce, '$expiresAt'].join('\n'),
  ),
);

String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List base64UrlDecodeNoPad(String s) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(s)) {
    throw const FormatException('not base64url');
  }
  return base64Url.decode(base64Url.normalize(s));
}

/// Converts the DER ECDSA signature Android Keystore emits into the 64-byte
/// raw r||s form the server verifies (WebCrypto style).
Uint8List ecdsaDerToRaw(Uint8List der, {int size = 32}) {
  int at = 0;
  int byte() {
    if (at >= der.length) throw const FormatException('short DER');
    return der[at++];
  }

  int length() {
    final b = byte();
    if (b < 0x80) return b;
    final n = b & 0x7f;
    if (n == 0 || n > 2) throw const FormatException('bad DER length');
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | byte();
    }
    return v;
  }

  if (byte() != 0x30) throw const FormatException('not a DER sequence');
  final total = length();
  if (at + total != der.length) throw const FormatException('DER length');
  final out = Uint8List(size * 2);
  for (var part = 0; part < 2; part++) {
    if (byte() != 0x02) throw const FormatException('not an integer');
    var n = length();
    if (at + n > der.length) throw const FormatException('short DER');
    var start = at;
    at += n;
    while (n > 0 && der[start] == 0) {
      start++;
      n--;
    }
    if (n > size) throw const FormatException('integer too large');
    out.setRange(part * size + (size - n), part * size + size, der, start);
  }
  if (at != der.length) throw const FormatException('trailing DER bytes');
  return out;
}

/// Raw uncompressed P-256 public point (0x04||X||Y) as base64url, the form
/// the server's exchange and Google routes take as renewal_key.
String encodeRenewalKey(Uint8List x, Uint8List y) {
  if (x.length != 32 || y.length != 32) {
    throw const FormatException('P-256 coordinates are 32 bytes');
  }
  return base64UrlNoPad([0x04, ...x, ...y]);
}
