import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_rule.dart';
import 'package:otpanda_client/native/native_action_proof.dart';
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/rule_action_contract.dart';

const now = 1800000000000;

class Source implements DeviceProofSource {
  int signs = 0;
  String? prompt;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => true;
  @override
  Future<Uint8List?> publicKeyOrNull() async => null;
  @override
  Future<Uint8List> createKeyForEnrollment() async => Uint8List(0);
  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    prompt = displayText;
    return Uint8List(64);
  }
}

Map<String, dynamic> begin({bool shared = true, String op = 'resume'}) {
  final descriptor = op == 'edit'
      ? [
          'edit',
          'email_address',
          'sender@example.test',
          'source',
          'service',
          'template',
          null,
          'phrase',
          'bank',
          0,
        ]
      : op == 'review'
      ? [
          'save',
          'email_address',
          'sender@example.test',
          null,
          'source',
          'service',
          null,
          true,
          0,
        ]
      : [
          'resume',
          'email_address',
          'sender@example.test',
          null,
          'source',
          'service',
          'template',
          null,
          0,
        ];
  final action = jsonEncode([
    'otpanda-rule',
    shared ? 6 : 5,
    'intent',
    'owner',
    'device',
    3,
    op,
    op == 'review' ? 'context' : 'rule',
    'entry',
    0,
    'a' * 64,
    op == 'review' ? now + 500000 : null,
    shared ? 2 : 0,
    0,
    !shared,
    jsonEncode(descriptor),
    if (shared) ...['Bank', '', 'service'],
  ]);
  return {
    'intentId': 'intent',
    'action': action,
    'expiresAt': now + 100000,
    'proofRequired': shared,
    'summary': {
      'operation': op == 'resume'
          ? 'rule-resume'
          : op == 'edit'
          ? 'rule-edit'
          : 'rule-from-review',
      'entryId': 'entry',
      'label': 'Bank',
      'accountName': null,
      'serviceId': 'service',
      'sender': 'sender@example.test',
      'senderKind': 'email_address',
      'basis': op == 'edit' ? 'phrase' : 'template',
      'phrase': op == 'edit' ? 'bank' : null,
      'futureRecipients': shared ? 2 : 0,
      'futureAutomations': 0,
      'otherAccountRules': 0,
      'irreversible': false,
      if (op == 'edit') ...{
        'basisBefore': 'template',
        'phraseBefore': null,
        'mayMatchOtherTemplates': true,
      } else ...{
        'addressScope': 'any-address-on-connector',
        if (op == 'review')
          'previewRemoved': true
        else
          'resumesPausedRule': true,
      },
    },
    if (shared) ...{
      'token': 'otpda_${'A' * 55}',
      'challenge': {
        'ownerId': 'owner',
        'keyId': 'key',
        'generation': 3,
        'purpose': 'step-up',
        'actionDigest': hashText(action),
        'challenge': 'C' * 43,
        'expiresAt': now + 100000,
      },
    },
  };
}

Map<String, dynamic> target([String op = 'resume']) => {
  'operation': op,
  'entryId': 'entry',
  if (op == 'review') 'contextId': 'context' else 'ruleId': 'rule',
  if (op == 'edit') 'phrase': 'bank',
};
void main() {
  test('v5/v6 review edit resume canonical parser and native labels', () {
    for (final op in ['review', 'edit', 'resume']) {
      for (final shared in [false, true]) {
        final b = begin(op: op, shared: shared);
        expect(
          validateRuleAction(
            b,
            target(op),
            now: now,
            ownerId: 'owner',
            deviceId: 'device',
            generation: 3,
          )['sender'],
          'sender@example.test',
        );
      }
    }
  });
  test('sender audience basis and signed labels tamper refuse', () {
    for (final key in ['sender', 'futureRecipients', 'basis']) {
      final b = begin();
      (b['summary'] as Map)[key] = 'tampered';
      expect(
        () => validateRuleAction(b, target(), now: now),
        throwsFormatException,
      );
    }
    final b = begin(), a = jsonDecode(b['action']) as List;
    a[16] = 'Wrong';
    b['action'] = jsonEncode(a);
    expect(
      () => validateRuleAction(b, target(), now: now),
      throwsFormatException,
    );
  });
  test(
    'shared rule only prompts after tap, exact unchanged action sent once',
    () async {
      final src = Source(), b = begin();
      final calls = <String>[], bodies = <Map<String, dynamic>>[];
      final d = NativeRuleDriver(
        source: src,
        identity: () async =>
            (ownerId: 'owner', deviceId: 'device', keyId: 'key'),
        now: () => now,
        delay: (_) async {},
        post: (p, body) async {
          calls.add(p);
          bodies.add(body);
          return (
            status: 200,
            body: p.endsWith('/begin')
                ? b
                : {
                    'status': 'applied',
                    'rule': {'status': 'resumed'},
                  },
          );
        },
      );
      await d.prepare(jsonEncode(target()));
      expect(src.signs, 0);
      expect(calls.length, 1);
      expect(await d.confirm(), 'applied');
      expect(src.signs, 1);
      expect(src.prompt, contains('2 people'));
      expect(bodies.last['action'], b['action']);
      expect(calls.where((p) => p.endsWith('/finish')).length, 1);
    },
  );
  test('private no ceremony, unknown result remains reconcilable without new mutation', () async {
    final src = Source();
    var finishes = 0;
    final d = NativeRuleDriver(
      source: src,
      identity: () async => (ownerId: 'owner', deviceId: 'device', keyId: null),
      now: () => now,
      delay: (_) async {},
      post: (p, body) async {
        if (p.endsWith('/begin')) {
          return (status: 200, body: begin(shared: false));
        }
        if (p.endsWith('/finish')) {
          finishes++;
          expect(body.keys.toSet(), {'action', 'intentId'});
          return (
            status: 200,
            body: {
              'status': 'applied',
              'rule': {'status': 'unknown'},
            },
          );
        }
        return (status: 200, body: {'status': 'pending'});
      },
    );
    await d.prepare(jsonEncode(target()));
    expect(await d.confirm(), 'unknown');
    expect(await d.reconcile(), 'pending');
    expect(finishes, 1);
    expect(src.signs, 0);
    expect(() => d.dismiss(), throwsStateError);
  });
  test('digest mismatch refuses before signing', () async {
    final src = Source(), b = begin();
    b['challenge']['actionDigest'] = 'b' * 64;
    final d = NativeRuleDriver(
      source: src,
      identity: () async =>
          (ownerId: 'owner', deviceId: 'device', keyId: 'key'),
      now: () => now,
      post: (p, body) async => (status: 200, body: b),
    );
    await expectLater(d.prepare(jsonEncode(target())), throwsFormatException);
    expect(src.signs, 0);
  });
}
