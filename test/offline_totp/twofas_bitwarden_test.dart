import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp.dart';

import 'offline_totp_test.dart' show fails;

// Own fixtures (written for this repo, not copied from any app). Shapes follow
// the 2FAS fields read in Aegis's importer and Bitwarden's help page.
const _s1 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
String _twofas(List<Map<String, Object?>> services, {int v = 4}) =>
    jsonEncode({'schemaVersion': v, 'services': services});
Map<String, Object?> _svc(
  String name,
  Map<String, Object?> otp, {
  String secret = _s1,
}) => {'name': name, 'secret': secret, 'otp': otp};

void main() {
  group('2FAS plain', () {
    test('imports TOTP with parameters; skips HOTP, Steam; marks defaults', () {
      final o = parseTwoFasBackup(
        _twofas([
          _svc('A', {
            'account': 'a@x',
            'issuer': 'A',
            'digits': 8,
            'period': 60,
            'algorithm': 'SHA512',
            'tokenType': 'TOTP',
          }),
          _svc('B', {'account': 'b@x'}),
          _svc('H', {'account': 'h@x', 'tokenType': 'HOTP', 'counter': 3}),
          _svc('S', {'account': 's@x', 'tokenType': 'STEAM'}),
          _svc('M', {'account': 'm@x', 'algorithm': 'MD5'}),
          _svc('D7', {'account': 'd@x', 'digits': 9}),
          _svc('Z', {'account': 'z@x'}, secret: '1!!!'),
        ]),
      );
      expect(o.accounts.length, 2);
      final a = o.accounts[0], b = o.accounts[1];
      expect((a.digits, a.period, a.algorithm), (8, 60, OtpAlgorithm.sha512));
      expect(a.assumed, isEmpty);
      expect((b.digits, b.period, b.algorithm), (6, 30, OtpAlgorithm.sha1));
      expect(b.assumed, OtpAssumption.values.toSet());
      expect(o.skipped.map((s) => (s.position, s.error)).toList(), [
        (3, OtpFormatError.unsupportedType),
        (4, OtpFormatError.unsupportedType),
        (5, OtpFormatError.unsupportedAlgorithm),
        (6, OtpFormatError.unsupportedDigits),
        (7, OtpFormatError.badSecret),
      ]);
      expect(o.skipped.first.accountName, 'h@x');
      expect(o.skipped.first.toString(), isNot(contains('h@x')));
    });

    test('encrypted, newer schema, wrong shapes', () {
      expect(
        () => parseTwoFasBackup(
          jsonEncode({'schemaVersion': 4, 'servicesEncrypted': 'a:b:c'}),
        ),
        fails(OtpFormatError.encrypted),
      );
      expect(
        () => parseTwoFasBackup(_twofas([], v: 5)),
        fails(OtpFormatError.unsupportedVersion),
      );
      for (final bad in ['nope', '[]', '{}', '{"schemaVersion":4}']) {
        expect(() => parseTwoFasBackup(bad), fails(OtpFormatError.malformed));
      }
      expect(
        () => parseTwoFasBackup(_twofas([])),
        fails(OtpFormatError.malformed),
        reason: 'nothing at all',
      );
    });
  });

  group('Bitwarden', () {
    const uri =
        'otpauth://totp/Acme:amy?secret=$_s1&issuer=Acme&algorithm=SHA256&digits=8&period=45';
    test('JSON import: otpauth, bare secret, steam, non-totp items', () {
      final o = parseBitwardenJson(
        jsonEncode({
          'encrypted': false,
          'items': [
            {
              'name': 'Acme',
              'login': {'username': 'amy', 'totp': uri},
            },
            {
              'name': 'Bare',
              'login': {
                'username': 'bob',
                'totp': 'gezd gnbv gy3t qojq gezd gnbv gy3t qojq',
              },
            },
            {
              'name': 'Steam',
              'login': {'username': 'cy', 'totp': 'steam://$_s1'},
            },
            {
              'name': 'Plain login',
              'login': {'username': 'dee', 'totp': null},
            },
            {'name': 'Note', 'type': 2},
          ],
        }),
      );
      expect(o.accounts.length, 2);
      expect(o.accounts[0].period, 45);
      expect(o.accounts[0].assumed, isEmpty);
      expect(o.accounts[1].assumed, OtpAssumption.values.toSet());
      expect(o.skipped.single.error, OtpFormatError.unsupportedType);
      expect(o.skipped.single.position, 3);
    });

    test('encrypted and malformed JSON', () {
      expect(
        () => parseBitwardenJson('{"encrypted":true,"items":[]}'),
        fails(OtpFormatError.encrypted),
      );
      expect(
        () => parseBitwardenJson('{"items":{}}'),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseBitwardenJson('{"items":[]}'),
        fails(OtpFormatError.malformed),
      );
    });

    test('CSV import with quoting, CRLF and extra columns', () {
      const csv =
          'folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\r\n'
          ',,login,"Ac,me",,,0,,amy,,"$uri"\r\n'
          ',,login,NoTotp,,,0,,x,,\r\n';
      final o = parseBitwardenCsv(csv);
      expect(o.accounts.single.digits, 8);
      expect(
        () => parseBitwardenCsv('a,b\n1,2'),
        fails(OtpFormatError.malformed),
      );
      expect(
        () => parseBitwardenCsv('name,login_totp\n"x,y'),
        fails(OtpFormatError.malformed),
      );
    });

    test('export then import round-trips, and CSV quotes awkward labels', () {
      final accts = [
        OtpAccount(
          issuer: 'Ac,me "Inc"',
          accountName: 'a b@x',
          secret: decodeBase32(_s1),
          algorithm: OtpAlgorithm.sha512,
          digits: 8,
          period: 20,
        ),
      ];
      var n = 0;
      final j = encodeBitwardenJson(accts, newUuid: () => 'id-${n++}');
      final back = parseBitwardenJson(j).accounts.single;
      expect(
        (
          back.issuer,
          back.accountName,
          back.period,
          back.digits,
          back.algorithm,
        ),
        ('Ac,me "Inc"', 'a b@x', 20, 8, OtpAlgorithm.sha512),
      );
      final c = parseBitwardenCsv(encodeBitwardenCsv(accts)).accounts.single;
      expect((c.issuer, c.period), ('Ac,me "Inc"', 20));
      expect(encodeOtpauthUri(c), encodeOtpauthUri(accts.single));
    });
  });

  group('review fixes', () {
    test('2FAS account falls back to label, then service name', () {
      final o = parseTwoFasBackup(
        _twofas([
          _svc('Svc1', {'label': 'lab@x'}),
          _svc('Svc2', {'account': ''}),
        ]),
      );
      expect(o.accounts.map((a) => a.accountName), ['lab@x', 'Svc2']);
    });

    test(
      'Bitwarden JSON: bad items are explicit skips at source positions',
      () {
        final o = parseBitwardenJson(
          jsonEncode({
            'items': [
              {
                'name': 'no totp',
                'login': {'totp': null},
              },
              'junk',
              {
                'name': 'N',
                'login': {'username': 'u', 'totp': 5},
              },
              {
                'name': 'Ok',
                'login': {
                  'username': 'o',
                  'totp': 'otpauth://totp/Ok:o?secret=$_s1&issuer=Ok',
                },
              },
            ],
          }),
        );
        expect(o.accounts.length, 1);
        expect(o.skipped.map((s) => (s.position, s.error)).toList(), [
          (2, OtpFormatError.malformed),
          (3, OtpFormatError.malformed),
        ]);
        expect(o.skipped.last.accountName, 'u');
      },
    );

    test('Bitwarden CSV: BOM, short rows and source row numbers', () {
      const row =
          ',,login,Ok,,,0,,o,,otpauth://totp/Ok:o?secret=$_s1&issuer=Ok';
      final o = parseBitwardenCsv(
        '\ufefffolder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n'
        ',,login,Short\n'
        '$row\n',
      );
      expect(o.accounts.length, 1);
      expect(o.skipped.single.position, 1);
      expect(o.skipped.single.error, OtpFormatError.malformed);
      // header without a username column does not read out of range
      expect(
        parseBitwardenCsv(
          'name,login_totp\nA,otpauth://totp/A:a?secret=$_s1&issuer=A',
        ).accounts.length,
        1,
      );
    });

    test(
      'CSV export refuses formula-looking labels instead of altering them',
      () {
        OtpAccount mk(String label) => OtpAccount(
          issuer: null,
          accountName: label,
          secret: decodeBase32(_s1),
        );
        expect(bitwardenCsvFormulaRisk(mk('=SUM(A1)')), isTrue);
        expect(bitwardenCsvFormulaRisk(mk('plain')), isFalse);
        expect(
          () => encodeBitwardenCsv([mk('@x')]),
          fails(OtpFormatError.notRepresentable),
        );
        expect(
          encodeBitwardenJson([mk('=SUM(A1)')], newUuid: () => 'u'),
          contains('=SUM(A1)'),
        );
      },
    );
  });
}
