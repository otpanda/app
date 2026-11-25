import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_action_proof.dart';
import 'package:otpanda_client/native/native_assignment.dart';
import 'package:otpanda_client/native/native_device_proof.dart';

typedef _R = ({int status, Map<String, dynamic>? body});

class _Src implements DeviceProofSource {
  int signs = 0;
  Object? fail;
  String? text;
  DeviceProofFields? fields;
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
    text = displayText;
    fields = f;
    if (fail != null) throw fail!;
    return Uint8List.fromList(List.filled(64, 7));
  }
}

const _now = 1000000;
final _token = 'otpda_${'A' * 55}';
const _me = (ownerId: 'O', deviceId: 'D', keyId: 'K');

class _Server {
  _Server({this.shared = false});
  final bool shared;
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  Object? beginAction; // override
  Map<String, dynamic> Function(Map<String, dynamic>)? beginEdit;
  _R Function(Map<String, dynamic>)? finish;
  final statuses = <_R>[];
  String intent = 'I1';

  List<Object?> actionList() => shared
      ? [
          'otpanda-assignment',
          2,
          intent,
          'O',
          'D',
          3,
          'S',
          'E',
          'N',
          4,
          'a' * 64,
          10,
          900000,
          2,
          1,
          true,
          'GitHub',
          'me@x.io',
          'github',
        ]
      : [
          'otpanda-assignment',
          1,
          intent,
          'O',
          'D',
          3,
          'S',
          'E',
          'N',
          4,
          'a' * 64,
          10,
          900000,
          0,
          0,
          true,
        ];

  Future<_R> post(String path, Map<String, dynamic> body) async {
    calls.add(path);
    bodies.add(body);
    if (path.endsWith('/begin')) {
      final action = (beginAction as String?) ?? jsonEncode(actionList());
      var res = <String, dynamic>{
        'intentId': intent,
        'expiresAt': _now + 100000,
        'action': action,
        'proofRequired': shared,
        'summary': {
          'operation': 'assign-code',
          'entryId': 'N',
          'label': 'GitHub',
          'accountName': 'me@x.io',
          'serviceId': 'github',
          'activeRecipients': shared ? 2 : 0,
          'automationRecipients': shared ? 1 : 0,
          'irreversible': true,
        },
        if (shared) 'token': _token,
        if (shared)
          'challenge': {
            'ownerId': 'O',
            'keyId': 'K',
            'generation': 3,
            'purpose': 'step-up',
            'actionDigest': hashText(action),
            'challenge': 'C' * 43,
            'expiresAt': _now + 100000,
          },
      };
      if (beginEdit != null) res = beginEdit!(res);
      return (status: 200, body: res);
    }
    if (path.endsWith('/finish')) {
      if (finish != null) return finish!(body);
      return (status: 200, body: {'status': 'assigned'});
    }
    if (statuses.isEmpty) return (status: 200, body: {'status': 'pending'});
    return statuses.removeAt(0);
  }
}

const _target =
    '{"sourceId":"S","eventId":"E","entryId":"N"}';

NativeAssignmentDriver _d(_Server s, _Src src, {Object? me = _me}) =>
    NativeAssignmentDriver(
      post: s.post,
      source: src,
      identity: () async => me as dynamic,
      now: () => _now,
      delay: (_) async {},
    );

void main() {
  test('allowlist: exact key sets only', () {
    expect(
      assignmentRequestAllowed('/v1/manage/assignment/begin', {
        'entryId': 'a',
        'eventId': 'b',
        'sourceId': 'c',
      }),
      isTrue,
    );
    expect(
      assignmentRequestAllowed('/v1/manage/assignment/begin', {
        'entryId': 'a',
        'eventId': 'b',
        'sourceId': 'c',
        'extra': 1,
      }),
      isFalse,
    );
    expect(
      assignmentRequestAllowed('/v1/manage/assignment/finish', {
        'action': 'x',
        'intentId': 'i',
        'token': 't',
      }),
      isFalse,
    );
    expect(
      assignmentRequestAllowed('/v1/manage/assignment/other', {}),
      isFalse,
    );
    expect(
      assignmentRequestAllowed('/v1/manage/assignment/status', {'intentId': 'i'}),
      isTrue,
    );
  });

  test('private: no key proof, no prompt, finish with action only', () async {
    final s = _Server(), src = _Src();
    final d = _d(s, src);
    final text = jsonDecode(await d.prepare(_target)) as Map;
    expect(text['proofRequired'], false);
    expect(text['activeRecipients'], 0);
    expect(d.state, 'confirm');
    expect(await d.confirm(), 'assigned');
    expect(src.signs, 0);
    expect(s.bodies.last.keys.toSet(), {'action', 'intentId'});
    expect(s.bodies.first.containsKey('keyId'), isTrue);
  });

  test('shared: validates, prompts once with parsed text, signs, finishes',
      () async {
    final s = _Server(shared: true), src = _Src();
    final d = _d(s, src);
    final summary = jsonDecode(await d.prepare(_target)) as Map;
    expect(summary['proofRequired'], true);
    expect(src.signs, 0, reason: 'no prompt at prepare');
    expect(await d.confirm(), 'assigned');
    expect(src.signs, 1);
    expect(src.text, contains('GitHub'));
    expect(src.text, contains('Shared with 2 people, 1 automation'));
    expect(src.fields!.purpose, 'step-up');
    expect(src.fields!.keyId, 'K');
    final fin = s.bodies.last;
    expect(fin.keys.toSet(), {'action', 'intentId', 'signature', 'token'});
    expect((fin['signature'] as String).length, 86);
  });

  test('shared without an enrolled key: no begin proof path', () async {
    final s = _Server(shared: true), src = _Src();
    final d = _d(s, src, me: (ownerId: 'O', deviceId: 'D', keyId: null));
    await expectLater(d.prepare(_target), throwsA(anything));
    expect(d.state, 'unavailable');
    expect(src.signs, 0);
  });

  group('refuses before any prompt', () {
    void bad(String name, void Function(_Server s) setup) {
      test(name, () async {
        final s = _Server(shared: true), src = _Src();
        setup(s);
        final d = _d(s, src);
        await expectLater(d.prepare(_target), throwsA(anything));
        expect(d.state, 'unavailable');
        expect(src.signs, 0);
        expect(s.calls.length, 1);
      });
    }

    bad('digest does not match the action', (s) {
      s.beginEdit = (r) => {
        ...r,
        'challenge': {
          ...(r['challenge'] as Map<String, dynamic>),
          'actionDigest': 'b' * 64,
        },
      };
    });
    bad('wrong owner in the action', (s) {
      s.beginEdit = (r) {
        final a = jsonDecode(r['action'] as String) as List;
        a[3] = 'X';
        final t = jsonEncode(a);
        return {
          ...r,
          'action': t,
          'challenge': {
            ...(r['challenge'] as Map<String, dynamic>),
            'actionDigest': hashText(t),
          },
        };
      };
    });
    bad('summary counts differ from the action', (s) {
      s.beginEdit = (r) => {
        ...r,
        'summary': {
          ...(r['summary'] as Map<String, dynamic>),
          'activeRecipients': 0,
        },
      };
    });
    bad('different entry than asked', (s) {
      s.beginEdit = (r) => {
        ...r,
        'summary': {...(r['summary'] as Map<String, dynamic>), 'entryId': 'Z'},
      };
    });
    bad('challenge for another key', (s) {
      s.beginEdit = (r) => {
        ...r,
        'challenge': {...(r['challenge'] as Map<String, dynamic>), 'keyId': 'Q'},
      };
    });
    bad('proof said not required for a shared target', (s) {
      s.beginEdit = (r) => {...r, 'proofRequired': false};
    });
    bad('control character in the label', (s) {
      s.beginEdit = (r) {
        final a = jsonDecode(r['action'] as String) as List;
        a[16] = 'Git\u202EHub';
        final t = jsonEncode(a);
        return {
          ...r,
          'action': t,
          'challenge': {
            ...(r['challenge'] as Map<String, dynamic>),
            'actionDigest': hashText(t),
          },
        };
      };
    });
    bad('expired', (s) {
      s.beginEdit = (r) => {...r, 'expiresAt': _now - 1};
    });
  });

  test('private with a proofRequired=false but nonzero recipients is refused',
      () async {
    final s = _Server(), src = _Src();
    s.beginEdit = (r) => {
      ...r,
      'summary': {...(r['summary'] as Map<String, dynamic>), 'activeRecipients': 1},
    };
    final d = _d(s, src);
    await expectLater(d.prepare(_target), throwsA(anything));
    expect(d.state, 'unavailable');
  });

  test('cancelled prompt: nothing sent, can start again', () async {
    final s = _Server(shared: true), src = _Src();
    src.fail = const DeviceProofFailure(DeviceProofFailureKind.cancelled);
    final d = _d(s, src);
    await d.prepare(_target);
    expect(await d.confirm(), 'cancelled');
    expect(s.calls.where((c) => c.endsWith('/finish')), isEmpty);
    src.fail = null;
    await d.prepare(_target);
    expect(d.state, 'confirm');
  });

  test('lost finish: status only, never a second sign or finish', () async {
    final s = _Server(shared: true), src = _Src();
    s.finish = (_) => throw Exception('network');
    s.statuses.addAll([
      (status: 200, body: {'status': 'pending'}),
      (status: 200, body: {'status': 'assigned'}),
    ]);
    final d = _d(s, src);
    await d.prepare(_target);
    expect(await d.confirm(), 'assigned');
    expect(src.signs, 1);
    expect(s.calls.where((c) => c.endsWith('/finish')).length, 1);
    expect(s.calls.where((c) => c.endsWith('/status')).length, 2);
  });

  test('odd finish answer and no status answer stays unknown, dismiss refused',
      () async {
    final s = _Server(), src = _Src();
    s.finish = (_) => (status: 409, body: null);
    s.statuses.addAll([(status: 503, body: null)]);
    final d = _d(s, src);
    await d.prepare(_target);
    expect(await d.confirm(), 'unknown');
    expect(() => d.dismiss(), throwsStateError);
    s.statuses.add((status: 200, body: {'status': 'not-assigned'}));
    expect(await d.reconcile(), 'not-assigned');
    d.dismiss();
    expect(d.state, 'idle');
  });

  test('clear() drops a late outcome and does not undo a sent write', () async {
    final s = _Server(), src = _Src();
    final d = _d(s, src);
    await d.prepare(_target);
    d.clear();
    expect(d.state, 'idle');
    await expectLater(d.confirm(), throwsStateError);
    expect(s.calls.where((c) => c.endsWith('/finish')), isEmpty);
  });

  test('a second prepare while one is open is refused', () async {
    final s = _Server(), src = _Src();
    final d = _d(s, src);
    await d.prepare(_target);
    await expectLater(d.prepare(_target), throwsStateError);
  });
}
