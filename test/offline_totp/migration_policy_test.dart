// Import policy: defaults are applied visibly, never silently; unsupported
// entries are skipped and reported, never mapped. Fixtures come from an
// independent Python protobuf encoder. Synthetic secrets only.
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

import 'offline_totp_test.dart' show fails, rfcB32;

const mixed =
    'otpauth-migration://offline?data=CkAKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEhlFeGFtcGxlOmFsaWNlQGV4YW1wbGUuY29tGgdFeGFtcGxlIAEoATACCiUKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgVob3RwMSABKAEwATgFCiUKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgdtZDVhY2N0IAQoATACCjgKIAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gEghCYW5rOmJvYhoEQmFuayACKAIwAgowCiABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIBIGdW5zcGVjIAAoADACCiMKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgV3ZWlyZCAJKAEwAhABGAEgACiJBg%3D%3D';
const badUtf8 =
    'otpauth-migration://offline?data=CiAKFDEyMzQ1Njc4OTAxMjM0NTY3ODkwEgJvayABKAEwAgogChQxMjM0NTY3ODkwMTIzNDU2Nzg5MBIC%2F%2F4gASgBMAIQARgBIAAoBQ%3D%3D';

void main() {
  group('google import provenance', () {
    test('every Google account records an assumed 30 s period', () {
      final b = parseMigrationUri(mixed, skipUnsupported: true);
      for (final a in b.accounts) {
        expect(a.period, 30);
        expect(a.assumed, contains(OtpAssumption.period));
      }
    });

    test(
      'unspecified algorithm and digits are assumptions, stated ones are not',
      () {
        final b = parseMigrationUri(mixed, skipUnsupported: true);
        final byName = {for (final a in b.accounts) a.accountName: a};
        expect(byName['alice@example.com']!.assumed, {OtpAssumption.period});
        expect(byName['bob']!.algorithm, OtpAlgorithm.sha256);
        expect(byName['bob']!.digits, 8);
        expect(byName['bob']!.assumed, {OtpAssumption.period});
        expect(byName['unspec']!.assumed, {
          OtpAssumption.period,
          OtpAssumption.algorithm,
          OtpAssumption.digits,
        });
      },
    );

    test('editing a parameter clears its assumption and keeps the rest', () {
      final a = parseMigrationUri(mixed, skipUnsupported: true).accounts.first;
      final e = a.withParameters(period: 60);
      expect(e.period, 60);
      expect(e.assumed, isEmpty);
      expect(a.period, 30, reason: 'original is immutable');
      final partial = parseMigrationUri(
        mixed,
        skipUnsupported: true,
      ).accounts.firstWhere((x) => x.accountName == 'unspec');
      expect(partial.withParameters(digits: 6).assumed, {
        OtpAssumption.period,
        OtpAssumption.algorithm,
      });
      expect(
        () => a.withParameters(period: 0),
        throwsA(isA<OtpFormatException>()),
      );
    });

    test('the secret survives an edit unchanged', () {
      final a = parseMigrationUri(mixed, skipUnsupported: true).accounts.first;
      expect(a.withParameters(period: 45).secretBytes(), a.secretBytes());
    });

    test('preview carries the assumptions', () {
      final b = parseMigrationUri(mixed, skipUnsupported: true);
      final items = previewImport(b.accounts);
      expect(
        items.every((i) => i.assumed.contains(OtpAssumption.period)),
        isTrue,
      );
    });
  });

  group('skipping unsupported entries', () {
    test('strict parsing still refuses the whole payload', () {
      expect(
        () => parseMigrationUri(mixed),
        fails(OtpFormatError.unsupportedType),
      );
    });

    test('lenient parsing imports the valid entries and reports the rest', () {
      final b = parseMigrationUri(mixed, skipUnsupported: true);
      expect(b.accounts.map((a) => a.accountName), [
        'alice@example.com',
        'bob',
        'unspec',
      ]);
      expect(b.skipped.map((s) => (s.position, s.error)), [
        (2, OtpFormatError.unsupportedType),
        (3, OtpFormatError.unsupportedAlgorithm),
        (6, OtpFormatError.unsupportedAlgorithm),
      ]);
    });

    test('unknown algorithm values are skipped, never mapped to SHA-1', () {
      final b = parseMigrationUri(mixed, skipUnsupported: true);
      expect(b.accounts.any((a) => a.accountName == 'weird'), isFalse);
      expect(b.accounts.any((a) => a.accountName == 'md5acct'), isFalse);
    });

    test('skip reports carry no label or secret', () {
      final b = parseMigrationUri(mixed, skipUnsupported: true);
      expect(b.skipped.join(), isNot(contains('hotp1')));
      expect(b.toString(), 'MigrationBatch(redacted)');
    });

    test('a payload that cannot be decoded is never skipped past', () {
      expect(
        () => parseMigrationUri(badUtf8, skipUnsupported: true),
        fails(OtpFormatError.malformed),
      );
    });

    test('assembling keeps skips with running positions across batches', () {
      final b = parseMigrationUri(mixed, skipUnsupported: true);
      final out = assembleBatchesWithSkipped([b]);
      expect(out.accounts.length, 3);
      expect(out.skipped.length, 3);
      expect(out.skipped.first.position, 2);
    });
  });

  group('export routing', () {
    test(
      'non-30 s accounts are routed to Key URIs, nothing is dropped or changed',
      () {
        final b = parseMigrationUri(mixed, skipUnsupported: true);
        final slow = b.accounts.first.withParameters(period: 60);
        final all = [slow, ...b.accounts.skip(1)];
        final plan = planMigrationExport(all);
        expect(plan.otpauthOnly.single.period, 60);
        expect(plan.google.length, 2);
        expect(plan.google.length + plan.otpauthOnly.length, all.length);
        expect(
          () => encodeMigrationUris(all, batchId: 7),
          fails(OtpFormatError.notRepresentable),
        );
        final uris = encodeMigrationUris(plan.google, batchId: 7);
        expect(uris, isNotEmpty);
        final text = encodeOtpauthList(plan.otpauthOnly);
        expect(text, contains('period=60'));
      },
    );
  });

  group('otpauth provenance and lists', () {
    const base = 'otpauth://totp/Example:alice?secret=$rfcB32&issuer=Example';
    test('absent period, digits and algorithm are assumptions', () {
      expect(parseOtpauthUri(base).assumed, {
        OtpAssumption.algorithm,
        OtpAssumption.digits,
        OtpAssumption.period,
      });
      expect(
        parseOtpauthUri('$base&algorithm=SHA1&digits=6&period=30').assumed,
        isEmpty,
      );
    });

    test(
      'a list imports the good lines and reports the rest by line number',
      () {
        final text = [
          base,
          '',
          'otpauth://hotp/X:y?secret=$rfcB32&counter=1',
          'not a uri',
          '  $base&algorithm=SHA256&digits=8&period=60  ',
          'otpauth://totp/Z:z?secret=$rfcB32&algorithm=MD5',
        ].join('\r\n');
        final out = parseOtpauthList(text);
        expect(out.accounts.length, 2);
        expect(out.accounts.last.period, 60);
        expect(out.skipped.map((s) => (s.position, s.error)), [
          (3, OtpFormatError.unsupportedType),
          (4, OtpFormatError.malformed),
          (6, OtpFormatError.unsupportedAlgorithm),
        ]);
      },
    );

    test('list round trip keeps every parameter', () {
      final src = parseOtpauthList(
        '$base&algorithm=SHA512&digits=8&period=45\n$base&period=15\n',
      ).accounts;
      final back = parseOtpauthList(encodeOtpauthList(src)).accounts;
      expect(back.length, 2);
      expect(back[0].algorithm, OtpAlgorithm.sha512);
      expect(back[0].digits, 8);
      expect(back[0].period, 45);
      expect(back[1].period, 15);
      expect(back.every((a) => a.assumed.isEmpty), isTrue);
    });

    test('empty and oversized input are refused', () {
      expect(() => parseOtpauthList(''), fails(OtpFormatError.malformed));
      expect(
        () => parseOtpauthList('\n\n  \n'),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseOtpauthList('x' * ((1 << 20) + 1)),
        fails(OtpFormatError.tooLarge),
      );
      expect(
        () => parseOtpauthList('\n' * 5001),
        fails(OtpFormatError.tooLarge),
      );
    });

    test('migration URIs in a list are skipped, not guessed', () {
      final out = parseOtpauthList('$base\n$mixed');
      expect(out.accounts.length, 1);
      expect(out.skipped.single.position, 2);
    });
  });
}
