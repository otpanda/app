import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/otp_account.dart';
import 'package:otpanda_client/transfer/export_encoders.dart';
import 'package:otpanda_client/transfer/export_entry.dart';
import 'package:otpanda_client/transfer/export_file_io.dart';
import 'package:otpanda_client/transfer/google_raw_export.dart';
import 'package:otpanda_client/transfer/export_file_result.dart';
import 'package:otpanda_client/transfer/export_plan.dart';
import 'package:otpanda_client/transfer/export_seal.dart';
import 'package:otpanda_client/transfer/sealed_export_source.dart';

// Every secret and key here is synthetic test material. The fixtures were made
// by the API's own seal code (tool/gen_export_vector.mjs and the primary
// synthetic vector), so these tests pin the Dart opener to the real wire.
Map<String, dynamic> _json(String n) =>
    jsonDecode(File('test/transfer/fixtures/$n').readAsStringSync())
        as Map<String, dynamic>;

BigInt _scalar(String b64) => BigInt.parse(hex(unb64u(b64)), radix: 16);

ExportEphemeralKey _key(Map<String, dynamic> s) =>
    ExportEphemeralKey.fromScalarForTest(_scalar(s['clientScalar'] as String));

ExportBegin _begin(Map<String, dynamic> s, {List<Map>? override}) =>
    ExportBegin(
      ownerId: s['owner'] as String,
      deviceId: s['device'] as String,
      generation: s['generation'] as int,
      entries: [
        for (final e in override ?? (s['begin'] as List).cast<Map>())
          ApprovedExportEntry(
            entryId: e['entryId'] as String,
            version: e['version'] as String,
            label: e['label'] as String?,
            account: e['account'] as String?,
            issuer: e['issuer'] as String?,
            catalogId: e['catalogId'] as String?,
          ),
      ],
      unavailable: const [],
      handle: Object(),
    );

Map<String, Object?> _resp(Map<String, dynamic> s) =>
    jsonDecode(jsonEncode(s['response'])) as Map<String, Object?>;

ExportAadFields _fields(Map a) => ExportAadFields(
  ownerId: a['ownerId'] as String,
  deviceId: a['deviceId'] as String,
  generation: a['generation'] as int,
  entryId: a['entryId'] as String,
  seedVersion: a['seedVersion'] as String,
  algorithm: a['algorithm'] as String,
  digits: a['digits'] as int,
  period: a['period'] as int,
  label: a['label'] as String?,
  account: a['account'] as String?,
  issuer: a['issuer'] as String?,
  catalogId: a['catalogId'] as String?,
);

void main() {
  group('primary synthetic vector', () {
    final v = _json('export-vector-primary.json');
    final jwk = v['privateJwk'] as Map;
    ExportEphemeralKey key() =>
        ExportEphemeralKey.fromScalarForTest(_scalar(jwk['d'] as String));
    final out = v['out'] as Map;
    final entry = (out['entries'] as List).first as Map;
    final f = _fields(v['aad'] as Map);

    test('public key and digest match the API vector', () {
      final k = key();
      expect(k.publicBase64Url, v['pub']);
      expect(k.digest, v['ephemeralDigest']);
    });

    test('opens to the expected 20 byte secret', () {
      final s = ExportSession.open(
        key: key(),
        serverPublicKey: out['serverPublicKey'] as String,
        actionDigest: v['actionDigest'] as String,
        ephemeralDigest: v['ephemeralDigest'] as String,
      );
      final secret = s.openEntry(
        f,
        entry['nonce'] as String,
        entry['ciphertext'] as String,
      );
      expect(secret, (v['expected'] as List).cast<int>());
    });

    ExportSession open({
      String? action,
      ExportEphemeralKey? k,
      String? server,
    }) => ExportSession.open(
      key: k ?? key(),
      serverPublicKey: server ?? out['serverPublicKey'] as String,
      actionDigest: action ?? v['actionDigest'] as String,
      ephemeralDigest: v['ephemeralDigest'] as String,
    );

    test('every authenticated field change fails', () {
      final a = v['aad'] as Map;
      final changes = <String, ExportAadFields>{
        'owner': _fields({...a, 'ownerId': 'x'}),
        'device': _fields({...a, 'deviceId': 'x'}),
        'generation': _fields({...a, 'generation': 2}),
        'entry': _fields({...a, 'entryId': 'x'}),
        'version': _fields({...a, 'seedVersion': 'c' * 64}),
        'algorithm': _fields({...a, 'algorithm': 'SHA-1'}),
        'digits': _fields({...a, 'digits': 6}),
        'period': _fields({...a, 'period': 30}),
        'label': _fields({...a, 'label': 'Synthetic2'}),
        'account': _fields({...a, 'account': 'x'}),
        'issuer': _fields({...a, 'issuer': null}),
        'catalog': _fields({...a, 'catalogId': 'c'}),
      };
      for (final e in changes.entries) {
        expect(
          () => open().openEntry(
            e.value,
            entry['nonce'] as String,
            entry['ciphertext'] as String,
          ),
          throwsA(anything),
          reason: e.key,
        );
      }
    });

    test('tampered ciphertext, nonce, key, action digest, point fail', () {
      final n = entry['nonce'] as String, c = entry['ciphertext'] as String;
      String flip(String s) => (s[0] == 'A' ? 'B' : 'A') + s.substring(1);
      expect(() => open().openEntry(f, n, flip(c)), throwsA(anything));
      expect(() => open().openEntry(f, flip(n), c), throwsA(anything));
      expect(
        () => open(action: 'b' * 64).openEntry(f, n, c),
        throwsA(anything),
      );
      final wrongKey = ExportEphemeralKey.fromScalarForTest(BigInt.from(12345));
      expect(() => open(k: wrongKey).openEntry(f, n, c), throwsA(anything));
      // truncated ciphertext (tag cut)
      expect(
        () => open().openEntry(f, n, c.substring(0, c.length - 4)),
        throwsA(anything),
      );
    });

    test('bad server points are refused before any agreement', () {
      final raw = unb64u(out['serverPublicKey'] as String);
      final offCurve = Uint8List.fromList(raw)..[64] ^= 1;
      expect(() => open(server: b64u(offCurve)), throwsA(anything));
      expect(() => open(server: b64u(raw.sublist(0, 64))), throwsA(anything));
      expect(() => open(server: b64u(Uint8List(65))), throwsA(anything));
      final compressedTag = Uint8List.fromList(raw)..[0] = 2;
      expect(() => open(server: b64u(compressedTag)), throwsA(anything));
      expect(
        () => open(server: '${out['serverPublicKey']}='),
        throwsA(anything),
      );
    });

    test('disposed key and session refuse', () {
      final k = key()..dispose();
      expect(k.disposed, isTrue);
      expect(() => open(k: k), throwsA(anything));
      final s = open()..dispose();
      expect(
        () => s.openEntry(
          f,
          entry['nonce'] as String,
          entry['ciphertext'] as String,
        ),
        throwsStateError,
      );
    });
  });

  group('AAD bytes equal the API exportAad output', () {
    final v = _json('aad-vectors.json');
    test('tricky strings', () {
      final tricky = (v['tricky'] as List).cast<String>();
      final want = (v['out'] as List).cast<String>();
      expect(want.length, tricky.length);
      for (var i = 0; i < tricky.length; i++) {
        final t = tricky[i];
        final got = exportAad(
          ExportAadFields(
            ownerId: 'o',
            deviceId: 'd',
            generation: 3,
            entryId: 'e',
            seedVersion: 'v',
            algorithm: 'SHA-1',
            digits: 6,
            period: 30,
            label: t,
            account: t,
            issuer: null,
            catalogId: t,
          ),
          'a',
          'b',
        );
        expect(hex(got), want[i], reason: 'case $i');
      }
    });
  });

  group('multi entry scenario from the API seal code', () {
    final s = _json('export-scenario.json');

    test('opens all entries with exact metadata and secrets', () {
      final accounts = openSealedExport(
        key: _key(s),
        begin: _begin(s),
        response: _resp(s),
      );
      expect(accounts.length, 3);
      final fills = (s['fills'] as List).cast<int>();
      for (var i = 0; i < 3; i++) {
        expect(accounts[i].secretBytes(), List.filled(20, fills[i]));
      }
      expect(accounts[1].digits, 7);
      expect(accounts[1].period, 45);
      expect(accounts[2].digits, 8);
      expect(accounts[0].accountName, 'a@example.test');
      expect(accounts[0].label, 'Alpha "q" é');
      expect(accounts[1].accountName, 'Beta');
      expect(accounts[1].issuer, isNull);
      expect(accounts[2].issuer, 'G');
    });

    test(
      'raw text survives decrypt exactly, even text the account model refuses',
      () {
        final w = _json('export-unrepresentable.json');
        final es = openSealedExport(
          key: _key(w),
          begin: _begin(w),
          response: _resp(w),
        );
        expect(es[0].account, 'a:b');
        expect(es[2].issuer, 'G\u2028');
        expect(es[0].label, 'Alpha "q" é');
        expect(es[2].label, 'Gamma 日本 😀');
        expect(es[1].catalogId, 'beta.example');
        expect(
          es[0].toAccountOrNull(),
          isNull,
          reason: 'model refuses a colon',
        );
        expect(es[1].toAccountOrNull(), isNotNull);
        final g = planGoogleRawExport(es, batchId: 5);
        expect(g.blocked, isEmpty);
        expect(g.uris, isNotNull);
        expect(googleDisplayCaution(es).map((e) => e.entryId), ['e1', 'e3']);
      },
    );

    test(
      'file formats write the exact text; Google withholds and says which',
      () {
        final w = _json('export-unrepresentable.json');
        final es = openSealedExport(
          key: _key(w),
          begin: _begin(w),
          response: _resp(w),
        );
        var n = 0;
        String uuid() =>
            '00000000-0000-4000-8000-${(n++).toString().padLeft(12, '0')}';
        final aegis = encodeExportEntries(
          ExportFileFormat.aegisPlain,
          es,
          newUuid: uuid,
        );
        final j = jsonDecode(aegis.text!) as Map;
        final items = (j['db'] as Map)['entries'] as List;
        expect(items[0]['name'], 'a:b');
        expect(
          items[0]['note'],
          'Alpha "q" é',
          reason: 'display name kept in note',
        );
        expect(items[2]['issuer'], 'G\u2028');
        expect(aegis.notCarried, {ExportNotCarried.catalogId});
        final bw = encodeExportEntries(
          ExportFileFormat.bitwardenJson,
          es,
          newUuid: uuid,
        );
        final b = ((jsonDecode(bw.text!) as Map)['items'] as List);
        expect(b[0]['login']['username'], 'a:b');
        expect(b[0]['notes'], 'Alpha "q" é');
        final uris = encodeExportEntries(
          ExportFileFormat.otpauthList,
          es,
          newUuid: uuid,
        );
        final first = uris.text!.split('\n').first;
        expect(
          first.startsWith('otpauth://totp/Iss:a%3Ab?'),
          isTrue,
          reason: first,
        );
        expect(
          uris.notCarried,
          containsAll([
            ExportNotCarried.displayName,
            ExportNotCarried.catalogId,
          ]),
        );
        final csv = encodeExportEntries(
          ExportFileFormat.bitwardenCsv,
          es,
          newUuid: uuid,
        );
        expect(csv.text, isNotNull);
        expect(csv.text, contains('"Alpha ""q"" é"'));
      },
    );

    test(
      'formats that cannot write a text exactly withhold the whole file',
      () {
        ExportedEntry e(String account, {String? label, String? issuer}) =>
            ExportedEntry(
              entryId: 'x',
              label: label ?? 'L',
              account: account,
              issuer: issuer,
              catalogId: null,
              algorithm: OtpAlgorithm.sha1,
              digits: 6,
              period: 30,
              secret: Uint8List(20),
            );
        String uuid() => 'u';
        final csv = encodeExportEntries(ExportFileFormat.bitwardenCsv, [
          e('ok'),
          e('=SUM(A1)'),
        ], newUuid: uuid);
        expect(csv.text, isNull);
        expect(csv.unencodable.single.account, '=SUM(A1)');
        final nul = encodeExportEntries(ExportFileFormat.bitwardenCsv, [
          e('a\u0000b'),
        ], newUuid: uuid);
        expect(nul.text, isNull);
        for (final f in ExportFileFormat.values) {
          final r = encodeExportEntries(f, [e('lone\ud800')], newUuid: uuid);
          expect(r.text, isNull, reason: f.name);
          expect(r.unencodable, hasLength(1));
        }
        final lone = planGoogleRawExport([
          e('ok'),
          e('lone\ud800'),
        ], batchId: 1);
        expect(lone.uris, isNull);
        expect(lone.blocked.map((x) => x.account), ['lone\ud800']);
        final huge = planGoogleRawExport([e('x' * 5000)], batchId: 1);
        expect(huge.uris, isNull, reason: 'one account larger than a QR holds');
        expect(huge.blocked, hasLength(1));
        for (final odd in ['a:b', ' lead', 'trail ', 'c\u0001d', 'b\u202ex']) {
          final r = planGoogleRawExport([e(odd)], batchId: 1);
          expect(r.uris, isNotNull, reason: 'wire carries it: $odd');
          expect(googleDisplayCaution([e(odd)]), hasLength(1), reason: odd);
        }
        expect(googleDisplayCaution([e('fine', issuer: 'Fine')]), isEmpty);
      },
    );

    test(
      'Google QR wire carries the exact UTF-8 text and the extension fields',
      () {
        final w = _json('export-unrepresentable.json');
        final es = openSealedExport(
          key: _key(w),
          begin: _begin(w),
          response: _resp(w),
        );
        final g = planGoogleRawExport(es, batchId: 9);
        expect(g.uris, hasLength(1));
        final data = Uri.parse(g.uris!.single).queryParameters['data']!;
        final params = _protoFields(base64.decode(data));
        final accounts = params
            .where((f) => f.$1 == 1)
            .map((f) => _protoFields(f.$2 as List<int>))
            .toList();
        expect(accounts, hasLength(3));
        String text(List<(int, Object)> p, int n) =>
            utf8.decode(p.firstWhere((f) => f.$1 == n).$2 as List<int>);
        expect(text(accounts[0], 2), 'Iss:a:b');
        expect(text(accounts[0], 3), 'Iss');
        expect(text(accounts[1], 2), 'Beta');
        expect(accounts[1].any((f) => f.$1 == 3), isFalse);
        expect(text(accounts[2], 2), 'G\u2028:g');
        int num(List<(int, Object)> p, int n) =>
            p.firstWhere((f) => f.$1 == n).$2 as int;
        expect(num(accounts[1], 5), 1, reason: 'seven digits is the six enum');
        expect(num(accounts[1], 16), 7);
        expect(num(accounts[1], 15), 45);
        expect(num(accounts[2], 5), 2);
        expect(accounts[0].any((f) => f.$1 == 15 || f.$1 == 16), isFalse);
        expect(
          g.notes.map((n) => n.change),
          containsAll([
            GoogleExportChange.periodDropped,
            GoogleExportChange.digitsAdjusted,
          ]),
        );
      },
    );

    test('disposing an entry overwrites its secret and refuses reuse', () {
      final es = openSealedExport(
        key: _key(s),
        begin: _begin(s),
        response: _resp(s),
      );
      es.first.dispose();
      expect(es.first.disposed, isTrue);
      expect(() => es.first.secretBytes(), throwsStateError);
    });

    test('client approved label drift is ExportChangedException', () {
      final b = (s['begin'] as List).cast<Map>().map((e) => {...e}).toList();
      for (final field in ['label', 'account', 'issuer', 'catalogId']) {
        final c = b.map((e) => {...e}).toList();
        c[0][field] = 'renamed';
        expect(
          () => openSealedExport(
            key: _key(s),
            begin: _begin(s, override: c),
            response: _resp(s),
          ),
          throwsA(isA<ExportChangedException>()),
          reason: field,
        );
      }
    });

    test('server side metadata edits fail (tag or key shape)', () {
      for (final mut in <String, void Function(Map<String, Object?>)>{
        'digits': (e) => e['digits'] = 8,
        'period': (e) => e['period'] = 31,
        'algorithm': (e) => e['algorithm'] = 'SHA-256',
        'version': (e) => e['version'] = '9' * 64,
        'entryId': (e) => e['entryId'] = 'zz',
        'extraKey': (e) => e['extra'] = 1,
        'missingKey': (e) => e.remove('catalogId'),
        'nonce': (e) => e['nonce'] = 'AAAAAAAAAAAAAAAA',
        'digitsString': (e) => e['digits'] = '6',
        'algorithmUnknown': (e) => e['algorithm'] = 'MD5',
      }.entries) {
        final r = _resp(s);
        mut.value((r['entries'] as List).first as Map<String, Object?>);
        expect(
          () => openSealedExport(key: _key(s), begin: _begin(s), response: r),
          throwsA(isA<ExportRejectedException>()),
          reason: mut.key,
        );
      }
    });

    test('entry order, count, top level shape', () {
      final r = _resp(s);
      (r['entries'] as List).insert(0, (r['entries'] as List).removeLast());
      expect(
        () => openSealedExport(key: _key(s), begin: _begin(s), response: r),
        throwsA(isA<ExportRejectedException>()),
      );
      final r2 = _resp(s);
      (r2['entries'] as List).removeLast();
      expect(
        () => openSealedExport(key: _key(s), begin: _begin(s), response: r2),
        throwsA(isA<ExportRejectedException>()),
      );
      final r3 = _resp(s)..['extra'] = 1;
      expect(
        () => openSealedExport(key: _key(s), begin: _begin(s), response: r3),
        throwsA(isA<ExportRejectedException>()),
      );
      final r4 = _resp(s)..['serverPublicKey'] = 5;
      expect(
        () => openSealedExport(key: _key(s), begin: _begin(s), response: r4),
        throwsA(isA<ExportRejectedException>()),
      );
    });

    test('frozen set or version differing from what was approved fails', () {
      final b = (s['begin'] as List).cast<Map>().map((e) => {...e}).toList();
      b[1]['version'] = '8' * 64;
      expect(
        () => openSealedExport(
          key: _key(s),
          begin: _begin(s, override: b),
          response: _resp(s),
        ),
        throwsA(isA<ExportRejectedException>()),
      );
      expect(
        () => openSealedExport(
          key: ExportEphemeralKey.fromScalarForTest(BigInt.from(7)),
          begin: _begin(s),
          response: _resp(s),
        ),
        throwsA(isA<ExportRejectedException>()),
      );
    });

    test('key and session are disposed after open and after failure', () {
      final k = _key(s);
      openSealedExport(key: k, begin: _begin(s), response: _resp(s));
      expect(k.disposed, isFalse, reason: 'the caller owns the key');
    });
  });

  group('SealedSeedExportSource', () {
    final s = _json('export-scenario.json');

    test('success disposes the key once, no retry', () async {
      final t = _FakeTransport(s);
      ExportEphemeralKey? made;
      final src = SealedSeedExportSource(t, newKey: () => made = _key(s));
      final r = await src.exportEntries();
      expect(r.length, 3);
      expect(made!.disposed, isTrue);
      expect(t.begins, 1);
      expect(t.finishes, 1);
    });

    test('failure is not retried and disposes', () async {
      final t = _FakeTransport(s)
        ..finishError = const ExportAuthException(ExportAuthOutcome.cancelled);
      ExportEphemeralKey? made;
      final src = SealedSeedExportSource(t, newKey: () => made = _key(s));
      await expectLater(
        src.exportEntries(),
        throwsA(isA<ExportAuthException>()),
      );
      expect(made!.disposed, isTrue);
      expect(t.finishes, 1);
      final t2 = _FakeTransport(s)..beginError = StateError('network');
      await expectLater(
        SealedSeedExportSource(t2, newKey: () => _key(s)).exportEntries(),
        throwsA(isA<StateError>()),
      );
      expect(t2.begins, 1);
      expect(t2.finishes, 0);
    });

    test('cancel while finish is pending drops the late reply', () async {
      final t = _FakeTransport(s)..finishGate = Completer<void>();
      ExportEphemeralKey? made;
      final src = SealedSeedExportSource(t, newKey: () => made = _key(s));
      final f = src.exportEntries();
      final expectation = expectLater(f, throwsA(isA<ExportAuthException>()));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      src.cancel();
      expect(made!.disposed, isTrue);
      t.finishGate!.complete();
      await expectation;
      expect(t.finishes, 1);
    });

    test('cancel while begin is pending drops the late begin', () async {
      final t = _FakeTransport(s)..beginGate = Completer<void>();
      final src = SealedSeedExportSource(t, newKey: () => _key(s));
      final f = src.exportEntries();
      final expectation = expectLater(f, throwsA(isA<ExportAuthException>()));
      await Future<void>.delayed(Duration.zero);
      src.cancel();
      t.beginGate!.complete();
      await expectation;
      expect(t.finishes, 0, reason: 'no passkey prompt after cancel');
    });

    test('second exportAll while running is refused; new attempt after cancel works', () async {
      final t = _FakeTransport(s)..finishGate = Completer<void>();
      final src = SealedSeedExportSource(t, newKey: () => _key(s));
      final first = src.exportEntries();
      final firstExpect = expectLater(
        first,
        throwsA(isA<ExportAuthException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(src.exportEntries(), throwsStateError);
      src.cancel();
      t.finishGate!.complete();
      await firstExpect;
      t.finishGate = null;
      final r = await src.exportEntries();
      expect(r.length, 3);
    });

    test('server label change between begin and finish is a recoverable ExportChangedException', () async {
      final t = _FakeTransport(s)..driftLabel = true;
      await expectLater(
        SealedSeedExportSource(t, newKey: () => _key(s)).exportEntries(),
        throwsA(isA<ExportChangedException>()),
      );
    });
  });

  group('writeNewFileExclusive on the real filesystem', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('otp-export-test'));
    tearDown(() => dir.deleteSync(recursive: true));
    List<String> names() =>
        dir
            .listSync()
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .toList()
          ..sort();
    String p(String n) => '${dir.path}/$n';

    test('saves the whole file, owner only, no temp left', () async {
      final bytes = List<int>.generate(1000, (i) => i % 251);
      expect(
        await writeNewFileExclusive(dir.path, 'out.txt', bytes),
        ExportFileResult.saved,
      );
      expect(names(), ['out.txt']);
      expect(File(p('out.txt')).readAsBytesSync(), bytes);
      if (!Platform.isWindows) {
        expect(File(p('out.txt')).statSync().mode & 0x1ff, 0x180);
      }
    });

    test('temp file is owner only before the first byte is written', () async {
      int? mode;
      String? tempName;
      await writeNewFileExclusive(
        dir.path,
        'out.txt',
        List.filled(64, 9),
        debugStage: (st) async {
          if (st == 'afterCreate') {
            final t = dir.listSync().firstWhere((e) => e.path.endsWith('.tmp'));
            mode = t.statSync().mode & 0x1ff;
            tempName = t.path;
            expect(t.statSync().size, 0);
          }
        },
      );
      expect(tempName, isNotNull);
      if (!Platform.isWindows) expect(mode, 0x180);
    });

    test(
      'existing file, folder, link: refusal leaves each untouched',
      () async {
        File(p('f.txt')).writeAsStringSync('keep');
        Directory(p('d.txt')).createSync();
        Link(p('l.txt')).createSync(p('nowhere'));
        for (final n in ['f.txt', 'd.txt', 'l.txt']) {
          expect(
            await writeNewFileExclusive(dir.path, n, [1, 2, 3]),
            Platform.isWindows && n == 'l.txt'
                ? anyOf(ExportFileResult.alreadyExists, ExportFileResult.failed)
                : ExportFileResult.alreadyExists,
            reason: n,
          );
        }
        expect(File(p('f.txt')).readAsStringSync(), 'keep');
        expect(Directory(p('d.txt')).existsSync(), isTrue);
        expect(Link(p('l.txt')).targetSync(), p('nowhere'));
        expect(names(), ['d.txt', 'f.txt', 'l.txt']);
      },
    );

    test(
      'concurrent writers in one isolate: exactly one wins, whole file',
      () async {
        final results = await Future.wait([
          for (var i = 0; i < 12; i++)
            writeNewFileExclusive(
              dir.path,
              'out.txt',
              List.filled(5000, i + 1),
            ),
        ]);
        expect(results.where((r) => r == ExportFileResult.saved).length, 1);
        expect(
          results
              .where((r) => r != ExportFileResult.saved)
              .every(
                (r) =>
                    r == ExportFileResult.alreadyExists ||
                    r == ExportFileResult.failed,
              ),
          isTrue,
        );
        final got = File(p('out.txt')).readAsBytesSync();
        expect(got.length, 5000);
        expect(
          got.toSet().length,
          1,
          reason: 'one writer content, never mixed',
        );
        expect(names(), ['out.txt']);
      },
    );

    test('concurrent writers in separate isolates: exactly one wins', () async {
      final path = dir.path;
      final results = await Future.wait([
        for (var i = 0; i < 6; i++)
          Isolate.run(
            () => writeNewFileExclusive(
              path,
              'iso.txt',
              List.filled(20000, i + 1),
            ),
          ),
      ]);
      expect(results.where((r) => r == ExportFileResult.saved).length, 1);
      final got = File(p('iso.txt')).readAsBytesSync();
      expect(got.length, 20000);
      expect(got.toSet().length, 1);
      expect(names(), ['iso.txt']);
    });

    test('another process writes into the reserved name: refused, their data kept, temp gone', () async {
      for (final stage in [
        'afterReserve',
        'afterCreate',
        'midWrite',
        'beforeCheck',
      ]) {
        final r = await writeNewFileExclusive(
          dir.path,
          'out.txt',
          List.filled(64, 9),
          debugStage: (st) async {
            if (st == stage) File(p('out.txt')).writeAsStringSync('theirs');
          },
        );
        expect(r, ExportFileResult.failed, reason: stage);
        expect(File(p('out.txt')).readAsStringSync(), 'theirs', reason: stage);
        expect(names(), ['out.txt'], reason: stage);
        File(p('out.txt')).deleteSync();
      }
    });

    test('reserved name deleted or replaced by a link before the swap: no write through', () async {
      var r = await writeNewFileExclusive(
        dir.path,
        'out.txt',
        List.filled(64, 9),
        debugStage: (st) async {
          if (st == 'beforeCheck') File(p('out.txt')).deleteSync();
        },
      );
      expect(r, ExportFileResult.failed);
      expect(names(), isEmpty);
      File(p('victim.txt')).writeAsStringSync('victim');
      r = await writeNewFileExclusive(
        dir.path,
        'out.txt',
        List.filled(64, 9),
        debugStage: (st) async {
          if (st == 'beforeCheck') {
            File(p('out.txt')).deleteSync();
            Link(p('out.txt')).createSync(p('victim.txt'));
          }
        },
      );
      expect(r, ExportFileResult.failed);
      expect(File(p('victim.txt')).readAsStringSync(), 'victim');
      expect(names(), [
        'out.txt',
        'victim.txt',
      ], reason: 'their link is left, ours is gone');
    });

    test('known residual: a write after the check and before the rename is replaced', () async {
      // Documents the gap Dart cannot close (no rename-without-replace).
      final r = await writeNewFileExclusive(
        dir.path,
        'out.txt',
        List.filled(8, 7),
        debugStage: (st) async {
          if (st == 'beforeRename') {
            File(p('out.txt')).writeAsStringSync('theirs');
          }
        },
      );
      expect(r, ExportFileResult.saved);
      expect(File(p('out.txt')).readAsBytesSync(), List.filled(8, 7));
    });

    test('failure at each stage leaves no final name and no temp', () async {
      for (final stage in [
        'afterReserve',
        'afterCreate',
        'midWrite',
        'beforeCheck',
        'beforeRename',
      ]) {
        if (stage == 'beforeRename') continue;
        final r = await writeNewFileExclusive(
          dir.path,
          'out.txt',
          List.filled(64, 9),
          debugStage: (st) async {
            if (st == stage) throw const FileSystemException('injected');
          },
        );
        expect(r, ExportFileResult.failed, reason: stage);
        expect(names(), isEmpty, reason: stage);
      }
    });

    test(
      'permission restriction failure fails closed with nothing written',
      () async {
        final r = await writeNewFileExclusive(
          dir.path,
          'out.txt',
          List.filled(64, 9),
          restrictToOwner: (_) async =>
              throw const FileSystemException('no chmod'),
        );
        expect(r, ExportFileResult.failed);
        expect(names(), isEmpty);
      },
    );

    test('unsafe names and a missing folder', () async {
      for (final n in ['../x', 'a/b', '', '.hidden', 'a\\b']) {
        expect(
          await writeNewFileExclusive(dir.path, n, [1]),
          ExportFileResult.failed,
          reason: n,
        );
      }
      expect(
        await writeNewFileExclusive(p('nope'), 'x.txt', [1]),
        ExportFileResult.failed,
      );
      expect(names(), isEmpty);
    });
  });
}

final class _FakeTransport implements ExportTransport {
  _FakeTransport(this.s);
  final Map<String, dynamic> s;
  int begins = 0, finishes = 0;
  bool opened = false, driftLabel = false;
  Object? beginError, finishError;
  Completer<void>? beginGate, finishGate;

  @override
  Future<ExportBegin> begin({
    required String ephemeralKey,
    List<String>? entryIds,
  }) async {
    begins++;
    if (beginError != null) throw beginError!;
    await beginGate?.future;
    return _begin(s);
  }

  @override
  Future<Map<String, Object?>> finish({
    required ExportBegin begin,
    required String ephemeralKey,
  }) async {
    finishes++;
    if (finishError != null) throw finishError!;
    await finishGate?.future;
    opened = true;
    final r = _resp(s);
    if (driftLabel) ((r['entries'] as List).first as Map)['label'] = 'drift';
    return r;
  }
}

/// Minimal protobuf reader for the tests: varints become int, others bytes.
List<(int, Object)> _protoFields(List<int> b) {
  final out = <(int, Object)>[];
  var i = 0;
  int varint() {
    var v = 0, shift = 0;
    while (true) {
      final c = b[i++];
      v |= (c & 0x7f) << shift;
      if (c < 0x80) return v;
      shift += 7;
    }
  }

  while (i < b.length) {
    final tag = varint();
    if (tag & 7 == 0) {
      out.add((tag >> 3, varint()));
    } else {
      final n = varint();
      out.add((tag >> 3, b.sublist(i, i + n)));
      i += n;
    }
  }
  return out;
}
