import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_action_proof.dart';

List<Object?> _arr({int v = 2, String label = 'Work', Object? ro = 3}) => [
  'otpanda-assignment',
  v,
  'I1',
  'O1',
  'D1',
  4,
  'S',
  'E',
  'ENT',
  9,
  'h',
  1,
  2,
  ro,
  1,
  true,
  label,
  'me@x.io',
  'svc',
];

ValidatedAssignmentAction? _run(
  String a, {
  String? digest,
  String purpose = 'step-up',
  String key = 'K',
  int exp = 100,
  String entry = 'ENT',
}) => validateAssignmentActionV2(
  a,
  intentId: 'I1',
  ownerId: 'O1',
  deviceId: 'D1',
  generation: 4,
  entryId: entry,
  challengeActionDigest: digest ?? hashText(a),
  challengePurpose: purpose,
  challengeKeyId: key,
  ownKeyId: 'K',
  challengeExpiresAt: exp,
  nowMs: 50,
);

void main() {
  test('v4 exact20 binds future template disclosure into native OS prompt', () {
    final a = _arr(v: 4)
      ..add(
        jsonEncode([
          'save',
          'email_address',
          'sender@example.test',
          null,
          'S',
          'svc',
          null,
          'v1:${'a' * 64}',
        ]),
      );
    final r = _run(jsonEncode(a))!;
    expect(r.rule?['basis'], 'template');
    expect(
      r.prompt,
      contains(
        'Future template matches from sender@example.test go here, shared with 3 people / 1 automations.',
      ),
    );
    expect(
      _run(jsonEncode(a..[1] = 2)),
      isNull,
      reason: 'legacy parser never accepts extra field',
    );
  });
  test('v4 skew and invalid descriptor never reaches native prompt', () {
    for (final version in [1, 2, 3, 5]) {
      final a = _arr(v: version)
        ..add(jsonEncode(['none', 'template_unavailable']));
      expect(_run(jsonEncode(a)), isNull);
    }
    for (final d in [
      [
        'save',
        'email_address',
        'sender@example.test',
        null,
        'WRONG',
        'svc',
        null,
        'v1:${'a' * 64}',
      ],
      [
        'save',
        'email_address',
        'sender@example.test',
        null,
        'S',
        'WRONG',
        null,
        'v1:${'a' * 64}',
      ],
      [
        'save',
        'email_address',
        'sender@example.test',
        null,
        'S',
        'svc',
        null,
        null,
      ],
    ]) {
      expect(_run(jsonEncode(_arr(v: 4)..add(jsonEncode(d)))), isNull);
    }
  });
  test('valid v2 action yields the readable text from parsed fields only', () {
    final a = jsonEncode(_arr());
    final r = _run(a)!;
    expect(
      r.prompt,
      'Assign this code to Work (me@x.io). Shared with 3 people, 1 automation. Cannot be undone.',
    );
  });

  test('any mismatch means no prompt', () {
    final a = jsonEncode(_arr());
    expect(_run(a, digest: hashText('x')), isNull, reason: 'digest');
    expect(
      _run(a, digest: hashText(hashText(a))),
      isNull,
      reason: 'double hash',
    );
    expect(_run(a, purpose: 'enroll'), isNull);
    expect(_run(a, key: 'OTHER'), isNull, reason: 'not our key');
    expect(_run(a, exp: 50), isNull, reason: 'expired');
    expect(_run(a, exp: 50 + 150001), isNull, reason: 'too long');
    expect(_run(a, exp: 50 + 150000), isNotNull);
    expect(_run(a, entry: 'NOPE'), isNull);
    expect(
      _run(jsonEncode(_arr(v: 1))),
      isNull,
      reason: 'v1 never signed here',
    );
    expect(_run(jsonEncode(_arr(ro: -1))), isNull);
    expect(_run(jsonEncode(_arr(ro: 1.5))), isNull);
    expect(
      _run(jsonEncode(_arr()..removeLast())),
      isNull,
      reason: '18 elements',
    );
    expect(_run(jsonEncode(_arr(label: 'a' * 65))), isNull);
    expect(_run(jsonEncode(_arr(label: 'a\u202eb'))), isNull, reason: 'bidi');
    expect(_run('not json'), isNull);
    final other = _arr()..[3] = 'EVIL';
    expect(_run(jsonEncode(other)), isNull, reason: 'owner');
    final gen = _arr()..[5] = 5;
    expect(_run(jsonEncode(gen)), isNull, reason: 'generation');
  });

  test('3072-byte bound is UTF-8 bytes', () {
    final a = jsonEncode(_arr(label: 'é' * 64));
    expect(_run(a), isNotNull);
    final big = _arr()..[10] = 'h' * 3100;
    expect(_run(jsonEncode(big)), isNull);
  });

  test('approval and adopt digests are recomputed single hashes', () {
    expect(
      approvalActionDigest(
        changeId: 'C',
        kind: 'passkey-add',
        target: null,
        ownerId: 'O',
        generation: 2,
      ),
      hashText('["enrolled-approval","C","passkey-add",null,"O",2]'),
    );
    expect(adoptActionDigest('ab'), hashText('["adopt-device-key-v1","ab"]'));
    expect(
      approvalPrompt(
        kind: 'weird',
        accountEmail: 'a',
        requesterLabel: null,
        requesterKind: 'web',
        requestedAtMs: 1,
        nowMs: 1,
        fingerprint: null,
      ),
      isNull,
    );
    expect(
      approvalPrompt(
        kind: 'device-key-add',
        accountEmail: 'a@b',
        requesterLabel: 'Pixel',
        requesterKind: 'android',
        requestedAtMs: 1,
        nowMs: 1,
        fingerprint: 'aaaa-bbbb-cccc-dddd',
      ),
      contains('aaaa-bbbb-cccc-dddd'),
    );
  });
}
