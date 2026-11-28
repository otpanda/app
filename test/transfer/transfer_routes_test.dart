import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/transfer/transfer_routes.dart';

void main() {
  test('protocol2 exact import allowlist, no legacy/export bodies', () {
    expect(
      transferRequestAllowed('/v1/manage/totp/batch-begin', {
        'protocol': 2,
        'batchNonce': 'v2:nonce',
        'items': [],
      }),
      true,
    );
    expect(
      transferRequestAllowed('/v1/manage/totp/batch-finish', {
        'protocol': 2,
        'admissionId': 'id',
        'batchNonce': 'v2:nonce',
        'items': [],
        'token': 't',
        'response': {},
      }),
      true,
    );
    expect(
      transferRequestAllowed('/v1/manage/totp/batch-outcome', {
        'protocol': 2,
        'admissionId': 'id',
        'batchNonce': 'v2:nonce',
        'fence': true,
      }),
      true,
    );
    expect(
      transferRequestAllowed('/v1/manage/totp/batch-begin', {
        'batchNonce': 'nonce',
        'items': [],
      }),
      false,
    );
    expect(
      transferRequestAllowed('/v1/manage/totp/batch-outcome', {
        'protocol': 2,
        'admissionId': 'id',
        'batchNonce': 'v2:nonce',
        'fence': false,
      }),
      false,
    );
    expect(
      transferRequestAllowed('/v1/manage/totp/export-begin', {
        'ephemeralKey': {},
      }),
      false,
    );
  });
}
