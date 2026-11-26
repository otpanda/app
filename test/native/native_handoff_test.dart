import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_handoff.dart';

void main() {
  const api = 'https://otpanda-api.abrahammurciano.workers.dev';
  test('PKCE matches RFC 7636 appendix B vector', () {
    expect(
      PkcePair.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });
  test('generated pair is url-safe, unpadded, 43 chars, fresh', () {
    final a = PkcePair.generate(Random(1)), b = PkcePair.generate(Random(2));
    expect(a.verifier.length, 43);
    expect(a.verifier, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(a.challenge, PkcePair.challengeFor(a.verifier));
    expect(a.verifier, isNot(b.verifier));
    expect(generateState(Random(3)).length, 43);
  });
  AppReturn? p(String u, [String s = 'st1']) =>
      parseAppReturn(Uri.parse(u), apiOrigin: api, expectedState: s);
  test('accepts the exact return', () {
    final r = p('$api/app-return#code=abc&state=st1')!;
    expect([r.code, r.state], ['abc', 'st1']);
  });
  test('accepts uppercase host and explicit 443', () {
    expect(
      p(
        'https://OTPANDA-API.abrahammurciano.workers.dev:443/app-return#code=abc&state=st1',
      ),
      isNotNull,
    );
  });
  test('rejects wrong host, scheme, path, query secrets, state, shapes', () {
    for (final u in [
      'https://evil.example/app-return#code=abc&state=st1',
      'http://otpanda-api.abrahammurciano.workers.dev/app-return#code=abc&state=st1',
      '$api/other#code=abc&state=st1',
      '$api/app-return?code=abc&state=st1',
      '$api/app-return?x=1#code=abc&state=st1',
      '$api/app-return#code=abc&state=nope',
      '$api/app-return#code=abc',
      '$api/app-return#code=&state=st1',
      '$api/app-return#code=a&code=b&state=st1',
      '$api/app-return',
      'https://user:pw@otpanda-api.abrahammurciano.workers.dev/app-return#code=abc&state=st1',
      'https://otpanda-api.abrahammurciano.workers.dev.evil.example/app-return#code=abc&state=st1',
      'https://evil.example@otpanda-api.abrahammurciano.workers.dev/app-return#code=abc&state=st1',
      'https://otpanda-api.abrahammurciano.workers.dev/app-return/#code=abc&state=st1',
      'https://otpanda-api.abrahammurciano.workers.dev/app-return/x#code=abc&state=st1',
      'https://otpanda-api.abrahammurciano.workers.dev/app-return#code=abc&state=st1&extra=1&code=z',
      'otpanda://otpanda-api.abrahammurciano.workers.dev/app-return#code=abc&state=st1',
      '$api/app-return#garbage',
      'https://otpanda-api.abrahammurciano.workers.dev:8443/app-return#code=abc&state=st1',
    ]) {
      expect(p(u), isNull, reason: u);
    }
  });
  test('proposed Pages launch URL is fragment-only with 43-char values', () {
    final pair = PkcePair.generate(Random(5));
    final s = generateState(Random(6));
    final u = pagesNativeLaunchUrl(pair.challenge, s);
    expect(u.hasQuery, isFalse);
    expect(
      u.toString(),
      'https://otpanda.github.io/app/#native=1&challenge=${pair.challenge}&state=$s',
    );
    expect(() => pagesNativeLaunchUrl('short', s), throwsArgumentError);
  });
}
