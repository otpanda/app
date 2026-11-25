import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_action_proof.dart';
import 'package:otpanda_client/native/native_adopt_device.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_routes.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
final _digest = publicKeyDigest(spkiToJwk(base64.decode(_spki)));
final _tok = 'otpda_${'A' * 55}';
final _kid = 'k_${'a1' * 20}';

class _Src implements DeviceProofSource {
  int signs = 0;
  String? text;
  DeviceProofFailure? fail;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => true;
  @override
  Future<Uint8List?> publicKeyOrNull() async => base64.decode(_spki);
  @override
  Future<Uint8List> createKeyForEnrollment() async =>
      throw StateError('never creates');
  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    text = displayText;
    if (fail != null) throw fail!;
    return Uint8List(64);
  }
}

Map<String, dynamic> _begin({
  String? digest,
  String owner = 'O',
  String key = '',
  String purpose = 'step-up',
  int exp = 100000,
}) => {
  'token': _tok,
  'challenge': {
    'ownerId': owner,
    'keyId': key.isEmpty ? _kid : key,
    'generation': 1,
    'purpose': purpose,
    'actionDigest': digest ?? adoptActionDigest(_digest),
    'challenge': 'C' * 43,
    'expiresAt': exp,
  },
};

void main() {
  AdoptDriver mk(
    _Src s,
    Map<String, ({int status, Map<String, dynamic>? body})> r, {
    List<String>? log,
    bool failOnAdopted = false,
    String? expected,
  }) {
    return AdoptDriver(
      source: s,
      routes: DeviceStatusRoutes((p, b) async {
        log?.add(p);
        final x = r[p];
        if (x == null) throw Exception('lost');
        return x;
      }),
      ownerId: 'O',
      accountEmail: 'me@x.io',
      expectedKeyId: expected ?? _kid,
      onAdopted: (k) async {
        if (failOnAdopted) throw Exception('disk');
        log?.add('adopted:$k');
      },
      clearAnchor: () async => log?.add('clear'),
      now: () => 1000,
    );
  }

  const beg = '/v1/manage/device-key/adopt-begin',
      fin = '/v1/manage/device-key/adopt-finish';

  test('typed confirm: native confirmation saved first, anchor cleared only after, readable text on the prompt', () async {
    final s = _Src(), log = <String>[];
    final r = await mk(
      s,
      {
        beg: (status: 200, body: _begin()),
        fin: (status: 200, body: {'status': 'enrolled', 'keyId': _kid}),
      },
      log: log,
      expected: _kid,
    ).adopt();
    expect(r, AdoptOutcome.adopted);
    expect(log, [beg, fin, 'adopted:$_kid', 'clear']);
    expect(s.text, contains('me@x.io'));
    expect(s.text!.length, lessThanOrEqualTo(300));
  });

  test('anything but a typed matching confirm keeps the anchor', () async {
    for (final fr in <({int status, Map<String, dynamic>? body})?>[
      (status: 200, body: {'status': 'enrolled', 'keyId': 'k_${'b2' * 20}'}),
      (status: 200, body: {'status': 'enrolled'}),
      (status: 201, body: {'status': 'enrolled', 'keyId': _kid}),
      (status: 409, body: null),
      null,
    ]) {
      final log = <String>[];
      final r = await mk(_Src(), {
        beg: (status: 200, body: _begin()),
        if (fr != null) fin: fr,
      }, log: log).adopt();
      expect(r, AdoptOutcome.notConfirmed, reason: '$fr');
      expect(log.contains('clear'), isFalse);
      expect(log.any((l) => l.startsWith('adopted')), isFalse);
    }
    final log = <String>[];
    final r = await mk(
      _Src(),
      {
        beg: (status: 200, body: _begin()),
        fin: (status: 200, body: {'status': 'enrolled', 'keyId': _kid}),
      },
      log: log,
      failOnAdopted: true,
    ).adopt();
    expect(r, AdoptOutcome.notConfirmed);
    expect(
      log.contains('clear'),
      isFalse,
      reason: 'native confirmation failed, anchor kept',
    );
  });

  test('a bad challenge never prompts: wrong digest, owner, purpose, keyId, expiry', () async {
    final cases = <Map<String, dynamic>>[
      _begin(digest: 'a' * 64),
      _begin(owner: 'EVIL'),
      _begin(purpose: 'enroll'),
      _begin(key: 'k_${'c3' * 20}'),
      _begin(exp: 1000),
      _begin(exp: 1000 + 150001),
    ];
    for (final c in cases) {
      final s = _Src();
      final r = await mk(s, {
        beg: (status: 200, body: c),
      }, expected: _kid).adopt();
      expect(r == AdoptOutcome.refused, isTrue, reason: '$c');
      expect(s.signs, 0);
    }
    final s = _Src();
    expect(
      await mk(s, {beg: (status: 200, body: null)}).adopt(),
      AdoptOutcome.refused,
    );
    expect(s.signs, 0);
  });

  test(
    'unsafe email, cancel and host refusal send nothing and keep everything',
    () async {
      final s = _Src();
      final d = AdoptDriver(
        source: s,
        routes: DeviceStatusRoutes((p, b) async => throw Exception('no')),
        ownerId: 'O',
        accountEmail: 'me\u202E@x.io',
        expectedKeyId: _kid,
        onAdopted: (_) async {},
        clearAnchor: () async {},
        now: () => 1000,
      );
      expect(await d.adopt(), AdoptOutcome.refused);
      final c = _Src()
        ..fail = const DeviceProofFailure(DeviceProofFailureKind.cancelled);
      final log = <String>[];
      expect(
        await mk(c, {beg: (status: 200, body: _begin())}, log: log).adopt(),
        AdoptOutcome.cancelled,
      );
      expect(log, [beg]);
      final h = _Src()
        ..fail = const DeviceProofFailure(DeviceProofFailureKind.unsupportedOs);
      expect(
        await mk(h, {beg: (status: 200, body: _begin())}).adopt(),
        AdoptOutcome.refused,
      );
    },
  );

  test(
    'the same challenge token is never signed twice by one driver',
    () async {
      final s = _Src();
      final d = mk(s, {beg: (status: 200, body: _begin())});
      expect(
        await d.adopt(),
        AdoptOutcome.notConfirmed,
      ); // finish lost (no route)
      expect(s.signs, 1);
      expect(await d.adopt(), AdoptOutcome.notConfirmed);
      expect(s.signs, 1);
    },
  );
}
