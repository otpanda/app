import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/otpauth.dart';

void main() {
  const s = 'JBSWY3DPEHPK3PXP';
  test('valid URI is returned unchanged with issuer and account', () {
    const u =
        'otpauth://totp/Example%20Co:alice%40example.com?secret=$s&issuer=Example%20Co&algorithm=SHA256&digits=8&period=60';
    final r = parseOtpauth(u);
    expect(r.name, 'Example Co');
    expect(r.issuer, 'Example Co');
    expect(r.account, 'alice@example.com');
    expect(r.uri, u);
    expect(r.toString(), isNot(contains(s)));
  });
  test('issuer from label prefix; label only becomes name', () {
    expect(parseOtpauth('otpauth://totp/GitHub:bob?secret=$s').name, 'GitHub');
    final r = parseOtpauth('otpauth://totp/bob?secret=$s');
    expect(r.name, 'bob');
    expect(r.issuer, isNull);
    expect(r.account, '');
  });
  test('leading spaces in the account are trimmed like the API', () {
    expect(parseOtpauth('otpauth://totp/%20a?secret=$s').name, 'a');
  });
  void bad(String uri, OtpauthProblem p) {
    try {
      parseOtpauth(uri);
      fail('expected $p');
    } on OtpauthException catch (e) {
      expect(e.problem, p);
      expect(e.message, isNot(contains(s)));
      expect(e.toString(), isNot(contains(s)));
    }
  }

  test('refuses exactly what the API grammar refuses', () {
    bad('https://x', OtpauthProblem.notOtpauth);
    bad('otpauth://hotp/a?secret=$s&counter=1', OtpauthProblem.notTotp);
    bad('otpauth://totp/a', OtpauthProblem.malformed);
    bad('otpauth://totp/a?issuer=x', OtpauthProblem.badSecret);
    bad('otpauth://totp/a?secret=abc', OtpauthProblem.badSecret);
    bad('otpauth://totp/a?secret=$s=', OtpauthProblem.badSecret);
    bad(
      'otpauth://totp/a?secret=$s&algorithm=sha1',
      OtpauthProblem.unsupportedAlgorithm,
    );
    bad(
      'otpauth://totp/a?secret=$s&algorithm=MD5',
      OtpauthProblem.unsupportedAlgorithm,
    );
    bad(
      'otpauth://totp/a?secret=$s&digits=7',
      OtpauthProblem.unsupportedDigits,
    );
    bad(
      'otpauth://totp/a?secret=$s&period=0',
      OtpauthProblem.unsupportedPeriod,
    );
    bad(
      'otpauth://totp/a?secret=$s&period=86401',
      OtpauthProblem.unsupportedPeriod,
    );
    bad(
      'otpauth://totp/a?secret=$s&period=030',
      OtpauthProblem.unsupportedPeriod,
    );
    bad(
      'otpauth://totp/a?secret=$s&image=x',
      OtpauthProblem.unsupportedParameter,
    );
    bad('otpauth://totp/a?secret=$s&secret=$s', OtpauthProblem.malformed);
    bad('otpauth://totp/a?secret=$s&issuer=', OtpauthProblem.malformed);
    bad('otpauth://totp/a?secret=$s&issuer=%zz', OtpauthProblem.malformed);
    bad('otpauth://totp/a%20b?secret=$s ', OtpauthProblem.malformed);
    bad('otpauth://totp/A:b?secret=$s&issuer=B', OtpauthProblem.issuerMismatch);
    bad('otpauth://totp/A:b:c?secret=$s', OtpauthProblem.badLabel);
  });

  group('secret decode limits', () {
    String u(String x) => 'otpauth://totp/a?secret=$x';
    test('length, tail bits and byte bounds follow the API decode', () {
      expect(parseOtpauth(u('A' * 16)).uri, u('A' * 16));
      expect(parseOtpauth(u('A' * 205)).uri, u('A' * 205)); // 128 bytes
      expect(parseOtpauth(u('A' * 10 + 'AAAAAA')).name, 'a');
    });
    test('refused shapes', () {
      for (final x in [
        'A' * 17, // non-canonical length
        'A' * 19,
        'A' * 15, // 9 bytes
        'A' * 208, // 130 bytes
        'A' * 209,
      ]) {
        expect(
          () => parseOtpauth(u(x)),
          throwsA(isA<OtpauthException>()),
          reason: x.length.toString(),
        );
      }
      // 207 chars decodes to 129 bytes.
      expect(
        () => parseOtpauth(u('A' * 207)),
        throwsA(isA<OtpauthException>()),
      );
      expect(
        () => parseOtpauth(u('${'A' * 204}B')),
        throwsA(isA<OtpauthException>()),
      );
      expect(
        () => parseOtpauth(u('${'A' * 3}=')),
        throwsA(isA<OtpauthException>()),
      );
    });
  });
}
