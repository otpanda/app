// Aegis plain vault import and export. The fixture follows the structure in
// Aegis docs/vault.md and its published plain test vault (7-digit entry, 20 s
// and 50 s periods, HOTP, Steam), with different synthetic secrets generated
// by an independent Python script.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

import 'offline_totp_test.dart' show fails;

const fixture =
    r'''{"version":1,"header":{"slots":null,"params":null},"db":{"version":3,"entries":[{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"amy","issuer":"Alpha","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"SHA1","digits":6,"period":30},"groups":[]},{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"ben","issuer":"Beta","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"MRSWMZ3INFVGW3DNNZXXA4LSON2HK5TXPB4XU634PV7H7AEBQKBQ","algo":"SHA256","digits":7,"period":20},"groups":[]},{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"cat","issuer":"Gamma","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"GIZTINJWG44DSOR3HQ6T4P2AIFBEGRCFIZDUQSKKJNGE2TSPKBIVEU2UKVLFOWCZLJNVYXK6L5QGCYTDMRSWMZ3INFVGW3DNNZXXA4I","algo":"SHA512","digits":8,"period":50},"groups":[]},{"type":"hotp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"dan","issuer":"Delta","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"SHA1","digits":6,"counter":1},"groups":[]},{"type":"steam","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"eve","issuer":"Epsilon","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"SHA1","digits":5,"period":30},"groups":[]},{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"fay","issuer":"","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"SHA1","digits":6},"groups":[]},{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"a:b","issuer":"Zeta","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"SHA1","digits":6,"period":30},"groups":[]},{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"gus","issuer":"Eta","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"MD5","digits":6,"period":30},"groups":[]},{"type":"totp","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"hal","issuer":"Theta","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"1!!!","algo":"SHA1","digits":6,"period":30},"groups":[]},{"type":"yandex","uuid":"3ae6f1ad-2e65-4ed2-a953-1ec0dff2386d","name":"ivy","issuer":"Iota","note":"","icon":null,"icon_mime":null,"icon_hash":null,"favorite":false,"info":{"secret":"AEBAGBAFAYDQQCIKBMGA2DQPCA","algo":"SHA256","digits":8,"period":30},"groups":[]}],"groups":[]}}''';

void main() {
  test('unknown well-formed outer version is unsupported; structural errors malformed', () {
    expect(
      () => parseAegisPlainVault('{"version":2,"header":{},"db":{}}'),
      fails(OtpFormatError.unsupportedVersion),
    );
    for (final raw in [
      '[]',
      '{}',
      '{"version":"2","header":{}}',
      '{"version":2}',
      '{"version":2,"header":null}',
    ]) {
      expect(() => parseAegisPlainVault(raw), fails(OtpFormatError.malformed));
    }
  });

  test('imports TOTP entries with their own algorithm, digits and period', () {
    final out = parseAegisPlainVault(fixture);
    final by = {for (final a in out.accounts) a.accountName: a};
    expect(by.keys, {'amy', 'cat', 'fay'});
    expect(by['cat']!.algorithm, OtpAlgorithm.sha512);
    expect(by['cat']!.digits, 8);
    expect(by['cat']!.period, 50);
    expect(by['cat']!.assumed, isEmpty);
    expect(by['cat']!.secretBytes(), List.generate(64, (i) => 50 + i));
    expect(by['amy']!.issuer, 'Alpha');
  });

  test('empty issuer becomes none, absent period is an assumption', () {
    final fay = parseAegisPlainVault(fixture).accounts
        .firstWhere((a) => a.accountName == 'fay');
    expect(fay.issuer, isNull);
    expect(fay.period, 30);
    expect(fay.assumed, {OtpAssumption.period});
  });

  test('unsupported entries are skipped with a reason, never converted', () {
    final out = parseAegisPlainVault(fixture);
    expect(out.skipped.map((s) => (s.position, s.error)), [
      (2, OtpFormatError.unsupportedDigits),
      (4, OtpFormatError.unsupportedType),
      (5, OtpFormatError.unsupportedType),
      (7, OtpFormatError.malformed),
      (8, OtpFormatError.unsupportedAlgorithm),
      (9, OtpFormatError.badSecret),
      (10, OtpFormatError.unsupportedType),
    ]);
    expect(out.skipped.join(), isNot(contains('dan')));
    // Safe labels identify what did not migrate (local preview only).
    expect(out.skipped.first.accountName, 'ben');
    expect(out.skipped.first.issuer, 'Beta');
  });

  test('encrypted vaults are refused as encrypted, not as garbage', () {
    final enc = jsonEncode({
      'version': 1,
      'header': {
        'slots': [<String, Object>{}],
        'params': {'nonce': 'aa', 'tag': 'bb'},
      },
      'db': 'AAAA',
    });
    expect(() => parseAegisPlainVault(enc), fails(OtpFormatError.encrypted));
  });

  test('wrong versions, shapes and sizes are refused', () {
    Map<String, Object?> v(int outer, int inner) => {
      'version': outer,
      'header': {'slots': null, 'params': null},
      'db': {'version': inner, 'entries': <Object>[], 'groups': <Object>[]},
    };
    expect(
      () => parseAegisPlainVault(jsonEncode(v(2, 3))),
      fails(OtpFormatError.unsupportedVersion),
    );
    expect(
      () => parseAegisPlainVault(jsonEncode(v(1, 4))),
      fails(OtpFormatError.unsupportedVersion),
      reason: 'well-formed container, unknown content version',
    );
    expect(
      () => parseAegisPlainVault(jsonEncode(v(1, 3))),
      fails(OtpFormatError.malformed),
      reason: 'no entries at all',
    );
    expect(() => parseAegisPlainVault('nope'), fails(OtpFormatError.malformed));
    expect(() => parseAegisPlainVault('[]'), fails(OtpFormatError.malformed));
    expect(
      () => parseAegisPlainVault(' ' * ((8 << 20) + 1)),
      fails(OtpFormatError.tooLarge),
    );
  });

  test('export then import keeps every parameter and secret', () {
    final src = parseAegisPlainVault(fixture).accounts;
    var n = 0;
    final json = encodeAegisPlainVault(
      src,
      newUuid: () =>
          '00000000-0000-4000-8000-${(n++).toString().padLeft(12, '0')}',
    );
    final back = parseAegisPlainVault(json);
    expect(back.skipped, isEmpty);
    expect(back.accounts.length, src.length);
    for (var i = 0; i < src.length; i++) {
      expect(back.accounts[i].issuer, src[i].issuer);
      expect(back.accounts[i].accountName, src[i].accountName);
      expect(back.accounts[i].algorithm, src[i].algorithm);
      expect(back.accounts[i].digits, src[i].digits);
      expect(back.accounts[i].period, src[i].period);
      expect(back.accounts[i].secretBytes(), src[i].secretBytes());
    }
    final root = jsonDecode(json) as Map;
    expect((root['header'] as Map)['slots'], isNull);
    expect(
      ((root['db'] as Map)['entries'] as List).first['uuid'],
      endsWith('000000000000'),
    );
  });
}
