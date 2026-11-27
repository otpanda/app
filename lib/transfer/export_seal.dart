import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

import '../offline_totp/otp_account.dart';

/// Client side of the sealed owner export. Byte-for-byte counterpart of
/// `src/totp-export-seal.js` in the API (label, AAD field order, HKDF salt and
/// info, nonce and tag sizes). The API source is authoritative; the synthetic
/// vector in test/transfer/export_seal_test.dart pins interoperability.
///
/// Memory note: Dart cannot erase BigInt, String or garbage-collected copies.
/// Every Uint8List this file owns is overwritten when it is no longer needed;
/// that is best effort, not a guarantee.
const exportSealLabel = 'otpanda-totp-export-seal-v1';

final _curve = pc.ECCurve_secp256r1();
final _p256Prime = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);

pc.SecureRandom _secureRandom() {
  final r = pc.FortunaRandom();
  final s = Random.secure();
  r.seed(
    pc.KeyParameter(
      Uint8List.fromList(List<int>.generate(32, (_) => s.nextInt(256))),
    ),
  );
  return r;
}

String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List unb64u(String s, {int? exactBytes}) {
  if (s.isEmpty || RegExp(r'[^A-Za-z0-9_-]').hasMatch(s)) {
    throw const FormatException('bad base64url');
  }
  final out = base64Url.decode(base64Url.normalize(s));
  if (b64u(out) != s || (exactBytes != null && out.length != exactBytes)) {
    throw const FormatException('bad base64url');
  }
  return Uint8List.fromList(out);
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String h) {
  if (h.length != 64 || RegExp(r'[^0-9a-f]').hasMatch(h)) {
    throw const FormatException('bad digest');
  }
  return Uint8List.fromList([
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _bigToBytes(BigInt v, int len) {
  final out = Uint8List(len);
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

BigInt _bytesToBig(List<int> b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

/// The client's per-attempt P-256 key. Generate one per export attempt and
/// [dispose] it on completion, cancel, failure and when the app leaves the foreground.
final class ExportEphemeralKey {
  ExportEphemeralKey._(this._d, this.publicRaw);

  /// A fresh random key (platform CSPRNG seeds the generator).
  factory ExportEphemeralKey.generate() {
    final gen = pc.ECKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(_curve),
          _secureRandom(),
        ),
      );
    final pair = gen.generateKeyPair();
    final pub = pair.publicKey.Q!;
    return ExportEphemeralKey._(
      pair.privateKey.d,
      Uint8List.fromList(pub.getEncoded(false)),
    );
  }

  /// Test-only: a key from a private scalar (the synthetic vector).
  factory ExportEphemeralKey.fromScalarForTest(BigInt d) {
    final q = _curve.G * d;
    return ExportEphemeralKey._(d, Uint8List.fromList(q!.getEncoded(false)));
  }

  BigInt? _d;
  final Uint8List publicRaw;
  bool get disposed => _d == null;
  String get publicBase64Url => b64u(publicRaw);

  /// sha256 hex of the raw 65 byte public key (the API's ephemeralDigest).
  String get digest => hex(sha256.convert(publicRaw).bytes);

  Uint8List _agree(Uint8List serverRaw) {
    final d = _d;
    if (d == null) throw StateError('export key disposed');
    final point = _validPoint(serverRaw);
    final shared = point * d;
    if (shared == null || shared.isInfinity) {
      throw const FormatException('bad point');
    }
    return _bigToBytes(shared.x!.toBigInteger()!, 32);
  }

  void dispose() => _d = null;
}

pc.ECPoint _validPoint(Uint8List raw) {
  if (raw.length != 65 || raw[0] != 4) throw const FormatException('bad point');
  final x = _bytesToBig(raw.sublist(1, 33)), y = _bytesToBig(raw.sublist(33));
  final p = _p256Prime;
  if (x >= p || y >= p) throw const FormatException('bad point');
  final a = _curve.curve.a!.toBigInteger()!,
      b = _curve.curve.b!.toBigInteger()!;
  if ((y * y - (x * x * x + a * x + b)) % p != BigInt.zero) {
    throw const FormatException('point not on curve');
  }
  return _curve.curve.createPoint(x, y);
}

Uint8List _hkdf32(Uint8List ikm, Uint8List salt, Uint8List info) {
  final prk = Hmac(sha256, salt).convert(ikm).bytes;
  return Uint8List.fromList(
    Hmac(sha256, prk).convert([...info, 1]).bytes,
  ); // one block is exactly 32 bytes
}

/// The metadata the server returns and authenticates, in the API's order.
final class ExportAadFields {
  const ExportAadFields({
    required this.ownerId,
    required this.deviceId,
    required this.generation,
    required this.entryId,
    required this.seedVersion,
    required this.algorithm,
    required this.digits,
    required this.period,
    required this.label,
    required this.account,
    required this.issuer,
    required this.catalogId,
  });
  final String ownerId, deviceId, entryId, seedVersion, algorithm;
  final int generation, digits, period;
  final String? label, account, issuer, catalogId;
}

/// JSON.stringify compatible text for the AAD array. Dart's encoder escapes
/// the same characters as JavaScript for these string and integer values.
Uint8List exportAad(
  ExportAadFields f,
  String actionDigest,
  String ephemeralDigest,
) => Uint8List.fromList(
  utf8.encode(
    jsonEncode([
      exportSealLabel,
      f.ownerId,
      f.deviceId,
      f.generation,
      f.entryId,
      f.seedVersion,
      f.algorithm,
      f.digits,
      f.period,
      actionDigest,
      ephemeralDigest,
      f.label,
      f.account,
      f.issuer,
      f.catalogId,
    ]),
  ),
);

/// The action digest the API binds (`totp-export-v1`, sorted frozen set,
/// sha256 of the raw ephemeral key). The client recomputes it itself and uses
/// it as the HKDF salt and in the AAD, so a server that sealed under a
/// different set, key, device or generation cannot be opened.
String exportActionDigest({
  required String ownerId,
  required String deviceId,
  required int generation,
  required List<({String entryId, String version})> frozen,
  required String ephemeralDigest,
}) => hex(
  sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'totp-export-v1',
            ownerId,
            deviceId,
            generation,
            [
              for (final e in frozen) [e.entryId, e.version],
            ],
            ephemeralDigest,
          ]),
        ),
      )
      .bytes,
);

/// Session key shared by every entry of one response.
final class ExportSession {
  ExportSession._(this._key, this._actionDigest, this._ephemeralDigest);

  factory ExportSession.open({
    required ExportEphemeralKey key,
    required String serverPublicKey,
    required String actionDigest,
    required String ephemeralDigest,
  }) {
    final serverRaw = unb64u(serverPublicKey, exactBytes: 65);
    final ikm = key._agree(serverRaw);
    final k = _hkdf32(
      ikm,
      _unhex(actionDigest),
      Uint8List.fromList(
        utf8.encode(
          '$exportSealLabel|$ephemeralDigest|${hex(sha256.convert(serverRaw).bytes)}',
        ),
      ),
    );
    ikm.fillRange(0, ikm.length, 0);
    return ExportSession._(k, actionDigest, ephemeralDigest);
  }

  Uint8List? _key;
  final String _actionDigest, _ephemeralDigest;

  /// Opens one entry. Throws on any tag, AAD, nonce or length mismatch. The
  /// caller must overwrite the returned bytes after use.
  Uint8List openEntry(ExportAadFields f, String nonce, String ciphertext) {
    final k = _key;
    if (k == null) throw StateError('export session disposed');
    final iv = unb64u(nonce, exactBytes: 12), ct = unb64u(ciphertext);
    if (ct.length < 16 + 10 || ct.length > 16 + 128) {
      throw const FormatException('bad length');
    }
    final cipher = pc.GCMBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.AEADParameters(
          pc.KeyParameter(k),
          128,
          iv,
          exportAad(f, _actionDigest, _ephemeralDigest),
        ),
      );
    return cipher.process(ct);
  }

  void dispose() {
    _key?.fillRange(0, _key!.length, 0);
    _key = null;
  }
}

OtpAlgorithm algorithmFromName(String n) => switch (n) {
  'SHA-1' => OtpAlgorithm.sha1,
  'SHA-256' => OtpAlgorithm.sha256,
  'SHA-512' => OtpAlgorithm.sha512,
  _ => throw const FormatException('bad algorithm'),
};
