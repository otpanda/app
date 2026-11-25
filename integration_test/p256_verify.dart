import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:otpanda_client/native/native_signing.dart' show ecdsaDerToRaw;

/// Independent ECDSA P-256 / SHA-256 verifier for test use only. It checks
/// what the device Keystore signed against the public point the app reported,
/// without trusting the code under test. Slow BigInt affine math is fine for a
/// handful of checks.
final _p = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final _n = BigInt.parse(
  'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
  radix: 16,
);
final _a = _p - BigInt.from(3);
final _gx = BigInt.parse(
  '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
  radix: 16,
);
final _gy = BigInt.parse(
  '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
  radix: 16,
);

typedef _Pt = (BigInt, BigInt)?;

BigInt _inv(BigInt v, BigInt m) => v.modInverse(m);

_Pt _add(_Pt p, _Pt q) {
  if (p == null) return q;
  if (q == null) return p;
  final (x1, y1) = p;
  final (x2, y2) = q;
  BigInt l;
  if (x1 == x2) {
    if ((y1 + y2) % _p == BigInt.zero) return null;
    l = ((BigInt.from(3) * x1 * x1 + _a) * _inv(BigInt.two * y1, _p)) % _p;
  } else {
    l = ((y2 - y1) * _inv((x2 - x1) % _p, _p)) % _p;
  }
  final x3 = (l * l - x1 - x2) % _p;
  final y3 = (l * (x1 - x3) - y1) % _p;
  return (x3, y3);
}

_Pt _mul(BigInt k, _Pt p) {
  _Pt r;
  var addend = p;
  while (k > BigInt.zero) {
    if (k.isOdd) r = _add(r, addend);
    addend = _add(addend, addend);
    k >>= 1;
  }
  return r;
}

BigInt _big(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

/// [point] is 0x04||X||Y (65 bytes). [derSignature] is what Keystore returns.
bool verifyP256Der(Uint8List point, Uint8List message, Uint8List derSignature) {
  if (point.length != 65 || point[0] != 4) return false;
  final Uint8List raw;
  try {
    raw = ecdsaDerToRaw(derSignature);
  } on FormatException {
    return false;
  }
  final r = _big(raw.sublist(0, 32)), s = _big(raw.sublist(32));
  if (r <= BigInt.zero || r >= _n || s <= BigInt.zero || s >= _n) return false;
  final qx = _big(point.sublist(1, 33)), qy = _big(point.sublist(33));
  // The point must lie on the curve.
  final b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16,
  );
  if ((qy * qy - (qx * qx * qx + _a * qx + b)) % _p != BigInt.zero) {
    return false;
  }
  final e = _big(sha256.convert(message).bytes);
  final w = _inv(s, _n);
  final u1 = (e * w) % _n, u2 = (r * w) % _n;
  final pt = _add(_mul(u1, (_gx, _gy)), _mul(u2, (qx, qy)));
  return pt != null && pt.$1 % _n == r;
}
