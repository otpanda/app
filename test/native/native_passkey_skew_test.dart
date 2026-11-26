import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_passkey.dart';

const _token = 'otpda_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _challenge = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _server = 1800000000000;
const _ttl = 120000;

Map<String, dynamic> _assertion(int exp) => {
  'token': _token,
  'expiresAt': exp,
  'options': {
    'rpId': 'otpanda.github.io',
    'userVerification': 'required',
    'challenge': _challenge,
    'allowCredentials': [],
  },
};

Map<String, dynamic> _creation(int exp) => {
  'token': _token,
  'expiresAt': exp,
  'options': {
    'rp': {'id': 'otpanda.github.io', 'name': 'OTPanda'},
    'user': {'id': 'dXNlcg', 'name': 'me', 'displayName': 'me'},
    'challenge': _challenge,
    'authenticatorSelection': {'userVerification': 'required'},
    'excludeCredentials': [],
  },
};

/// Server issues [exp] = serverNow + ttl; the device clock is off by [skew].
int _timeoutFor(
  Map<String, dynamic> Function(int) make,
  bool creation,
  int skew,
) {
  final now = _server + skew;
  final json = creation
      ? passkeyCreationRequestJson(
          make(_server + _ttl),
          nowMs: now,
          first: true,
        )
      : passkeyRequestJson(make(_server + _ttl), nowMs: now);
  return (jsonDecode(json) as Map)['timeout'] as int;
}

bool _rejects(
  Map<String, dynamic> Function(int) make,
  bool creation,
  int skew,
) {
  try {
    _timeoutFor(make, creation, skew);
    return false;
  } on PasskeyException catch (e) {
    expect(e.code, 'invalid');
    return true;
  }
}

void main() {
  for (final creation in [false, true]) {
    final make = creation ? _creation : _assertion;
    final name = creation ? 'create' : 'assert';
    group('$name expiry clock skew', () {
      test('device 1 s and 30 s behind the server is accepted, timeout capped at 120 s', () {
        // Device behind means device now is smaller: skew negative.
        expect(_timeoutFor(make, creation, -1000), 120000);
        expect(_timeoutFor(make, creation, -30000), 120000);
      });
      test('device 30 s ahead is accepted with the real remaining time', () {
        expect(_timeoutFor(make, creation, 30000), 90000);
      });
      test('device 130 s ahead fails closed (already expired)', () {
        expect(_rejects(make, creation, 130000), isTrue);
        expect(
          _rejects(make, creation, _ttl),
          isTrue,
          reason: 'exactly expired',
        );
      });
      test(
        'behind by exactly the tolerance passes, beyond it fails closed',
        () {
          expect(_timeoutFor(make, creation, -300000), 120000);
          expect(_rejects(make, creation, -300001), isTrue);
        },
      );
      test('an expiry far beyond ttl plus tolerance fails closed', () {
        final now = _server;
        final far = make(now + _ttl + 300001);
        final bad = creation
            ? () => passkeyCreationRequestJson(far, nowMs: now, first: true)
            : () => passkeyRequestJson(far, nowMs: now);
        expect(bad, throwsA(isA<PasskeyException>()));
      });
    });
  }
}
