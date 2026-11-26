// Synthetic secrets only (RFC 6238 test key and arbitrary bytes). The fixtures
// below were produced by an independent Python protobuf encoder, not by the
// code under test.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

const vectors = <String, String>{
  'single': 'otpauth-migration://offline?data=CkAKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEhlFeGFtcGxlOmFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACCi8KIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gEgNib2IaACACKAIwAhABGAEgACi5YA%3D%3D',
  'b0': 'otpauth-migration://offline?data=CjQKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEg1FeGFtcGxlOmFsaWNlGgdFeGFtcGxlIAEoATACEAEYAiAAKIkG',
  'b1': 'otpauth-migration://offline?data=Ci8KIGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6MDEyMzQ1EgVjYXJvbCADKAEwAhABGAIgASiJBg%3D%3D',
  'hotp': 'otpauth-migration://offline?data=CiQKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgFoGgFYIAEoATABOAUQARgBIAAoAQ%3D%3D',
  'md5': 'otpauth-migration://offline?data=CiIKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgFtGgFYIAQoATACEAEYASAAKAE%3D',
  'unknownfield': 'otpauth-migration://offline?data=CiIKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgF1GgFYIAEoATACSGMQARgBIAAoAQ%3D%3D',
  'otherbatch': 'otpauth-migration://offline?data=CiIKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgF6GgFYIAEoATACEAEYAiABKIoG',
};
Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
final s1 = hex('3132333435363738393031323334353637383930'),
    s2 = hex(
      '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
    ),
    s3 = hex(
      '6162636465666768696a6b6c6d6e6f707172737475767778797a303132333435',
    );
Matcher fails(OtpFormatError e) =>
    throwsA(isA<OtpFormatException>().having((x) => x.error, 'error', e));
const rfcB32 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

void main() {
  test('rejects duplicate singular fields in parameters and payload metadata', () {
    String uri(List<int> bytes) =>
        'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode(bytes))}';
    final param = [
      10,
      10,
      ...List.filled(10, 65),
      18,
      1,
      120,
      26,
      1,
      88,
      32,
      1,
      40,
      1,
      48,
      2,
    ];
    final extra = <List<int>>[
      [10, 10, ...List.filled(10, 66)],
      [18, 1, 121],
      [26, 1, 89],
      [32, 1],
      [40, 1],
      [48, 2],
    ];
    for (final field in extra) {
      final p = [...param, ...field];
      expect(
        () => parseMigrationUri(uri([10, p.length, ...p, 16, 1])),
        fails(OtpFormatError.malformed),
      );
    }
    for (final tag in [16, 24, 32, 40]) {
      expect(
        () => parseMigrationUri(
          uri([10, param.length, ...param, 16, 1, tag, 1, tag, 1]),
        ),
        fails(OtpFormatError.malformed),
      );
    }
  });
  test('migration supports explicit version one only', () {
    final param = [10, 10, ...List.filled(10, 65), 18, 1, 120, 48, 2];
    for (final version in [0, 2, 127]) {
      final u =
          'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode([10, param.length, ...param, 16, version]))}';
      expect(() => parseMigrationUri(u), fails(OtpFormatError.malformed));
    }
  });
  group('base32', () {
    test('RFC 4648 vectors and round trip', () {
      expect(
        encodeBase32(Uint8List.fromList('foobar'.codeUnits)),
        'MZXW6YTBOI',
      );
      expect(decodeBase32('MZXW6YTBOI======'), 'foobar'.codeUnits);
      expect(decodeBase32('mzxw6ytboi'), 'foobar'.codeUnits);
      expect(encodeBase32(s1), rfcB32);
      expect(decodeBase32(rfcB32), s1);
    });
    test('rejects bad characters and nonzero trailing bits', () {
      expect(() => decodeBase32('MZXW6YT1'), fails(OtpFormatError.badSecret));
      expect(
        () => decodeBase32('MZXW6YTBOJ'),
        fails(OtpFormatError.badSecret),
      ); // J has nonzero pad bits
      expect(() => decodeBase32(''), fails(OtpFormatError.badSecret));
    });
  });

  group('otpauth uri', () {
    test('parses a full URI', () {
      final a = parseOtpauthUri(
        'otpauth://totp/Example:alice@example.com?secret=$rfcB32&issuer=Example&algorithm=SHA256&digits=8&period=60',
      );
      expect(a.issuer, 'Example');
      expect(a.accountName, 'alice@example.com');
      expect(a.algorithm, OtpAlgorithm.sha256);
      expect([a.digits, a.period], [8, 60]);
      expect(a.secretBytes(), s1);
    });
    test('defaults and percent decoding', () {
      final a = parseOtpauthUri(
        'otpauth://totp/Acme%20Co:bob%40x.test?secret=$rfcB32',
      );
      expect(
        [a.issuer, a.accountName, a.digits, a.period, a.algorithm],
        ['Acme Co', 'bob@x.test', 6, 30, OtpAlgorithm.sha1],
      );
    });
    test('round trips through encode', () {
      final a = OtpAccount(
        issuer: 'A B',
        accountName: 'x+y@z',
        secret: s2,
        algorithm: OtpAlgorithm.sha512,
        digits: 8,
        period: 45,
      );
      final b = parseOtpauthUri(encodeOtpauthUri(a));
      expect(
        [b.issuer, b.accountName, b.algorithm, b.digits, b.period],
        [a.issuer, a.accountName, a.algorithm, a.digits, a.period],
      );
      expect(b.secretBytes(), s2);
      final n = OtpAccount(issuer: null, accountName: 'solo', secret: s1);
      expect(parseOtpauthUri(encodeOtpauthUri(n)).issuer, isNull);
    });
    test('refuses what it cannot represent exactly', () {
      final cases = <String, OtpFormatError>{
        'otpauth://hotp/X:a?secret=$rfcB32&counter=1':
            OtpFormatError.unsupportedType,
        'otpauth://totp/X:a?secret=$rfcB32&digits=9':
            OtpFormatError.unsupportedDigits,
        'otpauth://totp/X:a?secret=$rfcB32&algorithm=MD5':
            OtpFormatError.unsupportedAlgorithm,
        'otpauth://totp/X:a?secret=$rfcB32&period=0':
            OtpFormatError.unsupportedPeriod,
        'otpauth://totp/X:a?secret=$rfcB32&period=99999':
            OtpFormatError.unsupportedPeriod,
        'otpauth://totp/X:a?secret=$rfcB32&issuer=Y':
            OtpFormatError.conflictingMetadata,
        'otpauth://totp/X:a?secret=MZXW6YTB': OtpFormatError.badSecret,
        'otpauth://totp/X:a?secret=MZXW6YTB1': OtpFormatError.badSecret,
        'otpauth://totp/X:a?issuer=X': OtpFormatError.badSecret,
        'otpauth://totp/X:a?secret=$rfcB32&secret=$rfcB32':
            OtpFormatError.malformed,
        'otpauth://totp/X:a?secret=$rfcB32&extra=1': OtpFormatError.malformed,
        'otpauth://totp/X:a?secret=$rfcB32 ': OtpFormatError.malformed,
        'otpauth://totp/A:B:C?secret=$rfcB32': OtpFormatError.malformed,
        'otpauth://totp/X:a?secret=%zz': OtpFormatError.malformed,
        'https://totp/X:a?secret=$rfcB32': OtpFormatError.malformed,
      };
      cases.forEach(
        (u, e) => expect(() => parseOtpauthUri(u), fails(e), reason: e.name),
      );
    });
    test('size limits and redaction', () {
      expect(
        () => parseOtpauthUri(
          'otpauth://totp/X:a?secret=$rfcB32&issuer=${'x' * 3000}',
        ),
        fails(OtpFormatError.malformed),
      );
      final a = parseOtpauthUri('otpauth://totp/X:a?secret=$rfcB32');
      expect(a.toString(), isNot(contains('GEZD')));
      expect('$a', 'OtpAccount(redacted)');
      try {
        parseOtpauthUri('otpauth://totp/X:a?secret=$rfcB32&digits=9');
      } catch (e) {
        expect(e.toString(), isNot(contains('GEZD')));
      }
      final copy = a.secretBytes()..[0] = 0;
      expect(a.secretBytes()[0], s1[0]);
      expect(copy[0], 0);
      expect(
        () => OtpAccount(issuer: null, accountName: 'a', secret: Uint8List(9)),
        fails(OtpFormatError.badSecret),
      );
      expect(
        () => OtpAccount(issuer: null, accountName: ' a', secret: s1),
        fails(OtpFormatError.malformed),
      );
    });
  });

  group('google migration', () {
    test('parses independently generated payload', () {
      final b = parseMigrationUri(vectors['single']!);
      expect(
        [b.version, b.batchSize, b.batchIndex, b.batchId],
        [1, 1, 0, 12345],
      );
      expect(b.accounts.length, 2);
      final a = b.accounts[0], c = b.accounts[1];
      expect(
        [a.issuer, a.accountName, a.algorithm, a.digits, a.period],
        ['Example', 'alice@example.com', OtpAlgorithm.sha1, 6, 30],
      );
      expect(a.secretBytes(), s1);
      expect(
        [c.issuer, c.accountName, c.algorithm, c.digits],
        [null, 'bob', OtpAlgorithm.sha256, 8],
      );
      expect(c.secretBytes(), s2);
    });
    test('unknown fields are skipped; HOTP, MD5 and garbage are refused', () {
      expect(parseMigrationUri(vectors['unknownfield']!).accounts.length, 1);
      expect(
        () => parseMigrationUri(vectors['hotp']!),
        fails(OtpFormatError.unsupportedType),
      );
      expect(
        () => parseMigrationUri(vectors['md5']!),
        fails(OtpFormatError.unsupportedAlgorithm),
      );
      for (final bad in [
        'otpauth-migration://offline?data=',
        'otpauth-migration://offline?data=AAAA',
        'otpauth-migration://offline?data=!!!!',
        'otpauth-migration://other?data=CgA%3D',
        'otpauth-migration://offline?data=Cv8B', // length overrun
        'x' * 20000,
      ]) {
        expect(
          () => parseMigrationUri(bad),
          throwsA(isA<OtpFormatException>()),
          reason: bad.length > 60 ? 'long' : bad,
        );
      }
    });
    test('every truncation of a valid payload is refused or fully valid, never a crash', () {
      final full = vectors['single']!;
      for (var n = 0; n < full.length; n++) {
        try {
          parseMigrationUri(full.substring(0, n));
        } on OtpFormatException {
          // expected
        }
      }
    });
    test('negative int32 batch id (10-byte varint, from independent encoder) parses', () {
      final b = parseMigrationUri(
        'otpauth-migration://offline?data=CiEKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgNuZWcgASgBMAIQARgBIAAo%2B%2F%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FAQ%3D%3D',
      );
      expect(b.batchId, 4294967291);
      expect(b.accounts.single.accountName, 'neg');
    });
    test(
      'batches assemble in any order and reject mixed or incomplete sets',
      () {
        final b0 = parseMigrationUri(vectors['b0']!),
            b1 = parseMigrationUri(vectors['b1']!),
            other = parseMigrationUri(vectors['otherbatch']!);
        final all = assembleBatches([b1, b0]);
        expect(all.map((a) => a.accountName), ['alice', 'carol']);
        expect(all[1].algorithm, OtpAlgorithm.sha512);
        expect(
          () => assembleBatches([b0]),
          fails(OtpFormatError.incompleteBatch),
        );
        expect(
          () => assembleBatches([b0, b0]),
          fails(OtpFormatError.incompleteBatch),
        );
        expect(
          () => assembleBatches([b0, other]),
          fails(OtpFormatError.incompleteBatch),
        );
        expect(
          () => assembleBatches([]),
          fails(OtpFormatError.incompleteBatch),
        );
      },
    );
    test('encode round trips and splits into batches', () {
      final accts = [
        for (var i = 0; i < 25; i++)
          OtpAccount(
            issuer: i.isEven ? 'I$i' : null,
            accountName: 'u$i',
            secret: i.isEven ? s1 : s2,
            algorithm: OtpAlgorithm.values[i % 3],
            digits: i % 5 == 0 ? 8 : 6,
          ),
      ];
      final uris = encodeMigrationUris(accts, batchId: 4242);
      expect(uris.length, 3);
      final back = assembleBatches([
        for (final u in uris.reversed) parseMigrationUri(u),
      ]);
      expect(back.length, 25);
      for (var i = 0; i < 25; i++) {
        expect(
          [
            back[i].issuer,
            back[i].accountName,
            back[i].algorithm,
            back[i].digits,
          ],
          [
            accts[i].issuer,
            accts[i].accountName,
            accts[i].algorithm,
            accts[i].digits,
          ],
        );
        expect(back[i].secretBytes(), accts[i].secretBytes());
      }
    });
    test('export refuses accounts the format cannot carry exactly', () {
      expect(
        () => encodeMigrationUris([
          OtpAccount(issuer: null, accountName: 'a', secret: s1, period: 60),
        ], batchId: 1),
        fails(OtpFormatError.notRepresentable),
      );
      expect(
        () => encodeMigrationUris(
          [OtpAccount(issuer: null, accountName: 'a', secret: s1)],
          batchId: 1,
          perBatch: 0,
        ),
        fails(OtpFormatError.tooLarge),
      );
      expect(
        () => encodeMigrationUris([], batchId: 1),
        fails(OtpFormatError.tooLarge),
      );
    });
  });

  group('hostile protobuf bytes (same result on VM and JS)', () {
    List<int> v(int n) {
      final o = <int>[];
      while (n > 0x7f) {
        o.add((n & 0x7f) | 0x80);
        n = n ~/ 128;
      }
      return [...o, n];
    }

    List<int> ld(int tag, List<int> d) => [...v(tag), ...v(d.length), ...d];
    String uriOf(List<int> payload) =>
        'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode(payload))}';
    List<int> params({List<int>? extra}) => [
      ...ld(0x0a, s1),
      ...ld(0x12, utf8.encode('n')),
      0x20,
      1,
      0x28,
      1,
      0x30,
      2,
      ...?extra,
    ];

    test('a tag above 32 bits is malformed, never aliased to a real field', () {
      // 0x100000000 + 0x0a would look like field 1 / wire 2 if shifts truncate to 32 bits.
      final alias = ld(0x100000000 + 0x0a, params());
      expect(
        () => parseMigrationUri(uriOf(alias)),
        fails(OtpFormatError.malformed),
      );
      // A real account next to it does not rescue the batch: oversized tags are malformed.
      final both = [...ld(0x0a, params()), ...alias, 0x10, 1];
      expect(
        () => parseMigrationUri(uriOf(both)),
        fails(OtpFormatError.malformed),
      );
    });
    test('a length above 32 bits or a 64-bit overflow is malformed', () {
      expect(
        () => parseMigrationUri(uriOf([0x0a, ...v(0x100000000 + 5), 1, 2, 3])),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseMigrationUri(
          uriOf([
            0x0a,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0x7f,
          ]),
        ),
        fails(OtpFormatError.malformed),
      );
      // 11-byte varint
      expect(
        () => parseMigrationUri(uriOf([0x0a, ...List.filled(10, 0x80), 0x01])),
        fails(OtpFormatError.malformed),
      );
    });
    test('enum fields above 32 bits do not alias small values', () {
      // algorithm = 2^32 + 1 must not read as SHA1
      final p = [
        ...ld(0x0a, s1),
        ...ld(0x12, utf8.encode('n')),
        0x20,
        ...v(0x100000001),
        0x28,
        1,
        0x30,
        2,
      ];
      expect(
        () => parseMigrationUri(uriOf(ld(0x0a, p))),
        throwsA(isA<OtpFormatException>()),
      );
      // type = 2^32 + 2 must not read as TOTP
      final t = [
        ...ld(0x0a, s1),
        ...ld(0x12, utf8.encode('n')),
        0x20,
        1,
        0x28,
        1,
        0x30,
        ...v(0x100000002),
      ];
      expect(
        () => parseMigrationUri(uriOf(ld(0x0a, t))),
        throwsA(isA<OtpFormatException>()),
      );
    });
    test('wire type 3/4 groups and bad wire types are refused', () {
      expect(
        () => parseMigrationUri(uriOf([...ld(0x0a, params()), 0x13])),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseMigrationUri(uriOf([...ld(0x0a, params()), 0x17])),
        fails(OtpFormatError.malformed),
      );
    });
    test('padded or unpadded, standard or URL-safe base64 decode the same; junk is refused', () {
      final ok = base64.encode([...ld(0x0a, params()), 0x10, 1]);
      for (final d in [
        ok,
        ok.replaceAll('=', ''),
        ok.replaceAll('+', '-').replaceAll('/', '_'),
      ]) {
        expect(
          parseMigrationUri(
            'otpauth-migration://offline?data=${Uri.encodeQueryComponent(d)}',
          ).accounts.length,
          1,
        );
      }
      expect(
        () => parseMigrationUri('otpauth-migration://offline?data=$ok%'),
        throwsA(isA<OtpFormatException>()),
      );
    });
  });

  group('legacy and unusual labels', () {
    List<int> v(int n) => n < 128 ? [n] : [(n & 0x7f) | 0x80, n >> 7];
    List<int> ld(int tag, List<int> d) => [tag, ...v(d.length), ...d];
    String one(String name, {String? issuer}) {
      final p = [
        ...ld(0x0a, s1),
        ...ld(0x12, utf8.encode(name)),
        if (issuer != null) ...ld(0x1a, utf8.encode(issuer)),
        0x20,
        1,
        0x28,
        1,
        0x30,
        2,
      ];
      return 'otpauth-migration://offline?data=${Uri.encodeQueryComponent(base64.encode([...ld(0x0a, p), 0x10, 1, 0x18, 1, 0x20, 0, 0x28, 1]))}';
    }

    test('legacy Google entry: no issuer field, name "Issuer:account"', () {
      final a = parseMigrationUri(one('Acme:bob')).accounts.single;
      expect([a.issuer, a.accountName], ['Acme', 'bob']);
      final b = parseMigrationUri(one('Acme: bob')).accounts.single;
      expect([b.issuer, b.accountName], ['Acme', 'bob']);
      expect(parseMigrationUri(one('plain')).accounts.single.issuer, isNull);
    });
    test('ambiguous or contradictory names are refused, not guessed', () {
      expect(
        () => parseMigrationUri(one('A:B:C')),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseMigrationUri(one('Other:bob', issuer: 'Acme')),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseMigrationUri(one(':bob')),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseMigrationUri(one('Acme:')),
        fails(OtpFormatError.malformed),
      );
    });
    test('invisible and bidirectional characters in labels are refused', () {
      for (final c in [
        '\u200b',
        '\u200e',
        '\u202e',
        '\u2066',
        '\u2060',
        '\ufeff',
        '\u00ad',
        '\u0085',
        '\u2028',
        '\u061c',
        '\u180e',
        '\u007f',
        '\u009f',
      ]) {
        expect(
          () => OtpAccount(issuer: null, accountName: 'a${c}b', secret: s1),
          fails(OtpFormatError.malformed),
          reason: c.codeUnitAt(0).toRadixString(16),
        );
        expect(
          () => OtpAccount(issuer: 'x$c', accountName: 'a', secret: s1),
          fails(OtpFormatError.malformed),
        );
      }
      // ordinary non-ASCII text stays valid
      expect(
        OtpAccount(
          issuer: 'Café',
          accountName: 'משתמש@example.com',
          secret: s1,
        ).accountName,
        'משתמש@example.com',
      );
    });
  });

  group('export size', () {
    test(
      'large accounts are split so every URI is within our own decoder limit',
      () {
        final big = 'ש' * 120;
        final accts = [
          for (var i = 0; i < 40; i++)
            OtpAccount(
              issuer: big,
              accountName: '$i$big',
              secret: Uint8List.fromList(
                List.generate(128, (j) => (i * 7 + j) & 0xff),
              ),
              algorithm: OtpAlgorithm.sha512,
            ),
        ];
        final uris = encodeMigrationUris(accts, batchId: 99, perBatch: 50);
        expect(uris.length, greaterThan(1));
        for (final u in uris) {
          expect(u.length, lessThanOrEqualTo(maxMigrationUriLength));
        }
        final back = assembleBatches([
          for (final u in uris) parseMigrationUri(u),
        ]);
        expect(back.length, 40);
        for (var i = 0; i < 40; i++) {
          expect(back[i].accountName, accts[i].accountName);
          expect(back[i].secretBytes(), accts[i].secretBytes());
        }
      },
    );
  });

  group('import preview', () {
    test('exposes metadata only and flags duplicates', () {
      final a = parseOtpauthUri('otpauth://totp/X:a?secret=$rfcB32');
      final p = previewImport(
        [a, a, parseOtpauthUri('otpauth://totp/Y:b?secret=$rfcB32')],
        existingKeys: {('Y', 'b')},
      );
      expect(p.map((e) => e.duplicateOfExisting), [false, true, true]);
      expect(p.first.secretBits, 160);
    });
  });
}
