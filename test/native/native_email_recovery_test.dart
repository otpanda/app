import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_email_recovery.dart';
import 'package:otpanda_client/native/native_passkey.dart';
import 'package:otpanda_client/recovery_contract.dart';

class _Create implements PasskeyCreationSource {
  _Create(this.out);
  final String? out;
  int calls = 0;
  @override
  bool get available => true;
  @override
  Future<String?> create(String requestJson) async {
    calls++;
    return out;
  }
}

const _created =
    '{"id":"i","rawId":"i","type":"public-key","response":{"clientDataJSON":"c","attestationObject":"o","transports":["internal"]}}';
String _tok(String c) => 'otpda_${c * 55}';

void main() {
  late int now;
  late List<(String, Map<String, dynamic>)> sent;
  late Map<String, ({int status, Map<String, dynamic>? body})> replies;
  late _Create creator;
  var n = 0;

  NativeEmailRecovery make() => NativeEmailRecovery(
    post: (p, b) async {
      sent.add((p, Map<String, dynamic>.from(b)));
      final r = replies[p];
      if (r == null) throw Exception('network');
      return r;
    },
    creation: creator,
    nowMs: () => now,
    random: () => 'B${(n++).toString().padLeft(53, '0')}',
  );

  setUp(() {
    now = DateTime.now().millisecondsSinceEpoch;
    sent = [];
    replies = {};
    creator = _Create(_created);
  });

  Map<String, dynamic> begun() => {
    'grant': _tok('G'),
    'ceremony': {
      'token': _tok('C'),
      'expiresAt': now + 100000,
      'options': {
        'rp': {'id': 'otpanda.github.io', 'name': 'OTPanda'},
        'user': {'id': 'dXNlcg', 'name': 'a@b.c', 'displayName': 'a@b.c'},
        'challenge': 'A' * 43,
        'authenticatorSelection': {'userVerification': 'required'},
        'excludeCredentials': [],
      },
    },
  };

  test('start sends a 54-char binding and the canonical email', () async {
    replies['/auth/native/recovery/email/request'] = (status: 200, body: {});
    await make().start('  A@B.Co ');
    final b = sent.single.$2;
    expect(b['email'], 'a@b.co');
    expect((b['binding'] as String).length, 54);
  });

  test(
    'verify reuses the request binding, normalises the code, drops it',
    () async {
      replies['/auth/native/recovery/email/request'] = (status: 200, body: {});
      replies['/auth/native/recovery/email/verify'] = (
        status: 200,
        body: {'status': 'waiting', 'availableAt': now + 1000},
      );
      final r = make();
      await r.start('a@b.co');
      final at = await r.verify('a@b.co', 'abcd-2345');
      expect(at.millisecondsSinceEpoch, now + 1000);
      expect(sent[1].$2['binding'], sent[0].$2['binding']);
      expect(sent[1].$2['code'], 'ABCD2345');
      await expectLater(r.verify('a@b.co', 'ABCD2345'), throwsFormatException);
    },
  );

  test(
    'verify without start, wrong email, bad code or expired binding fails',
    () async {
      replies['/auth/native/recovery/email/request'] = (status: 200, body: {});
      final r = make();
      await expectLater(r.verify('a@b.co', 'ABCD2345'), throwsFormatException);
      await r.start('a@b.co');
      await expectLater(r.verify('x@b.co', 'ABCD2345'), throwsFormatException);
      await expectLater(r.verify('a@b.co', 'ABCD234'), throwsFormatException);
      now += NativeEmailRecovery.bindingTtlMs + 1;
      await expectLater(r.verify('a@b.co', 'ABCD2345'), throwsFormatException);
    },
  );

  test('complete: code, new passkey, finish needs status completed', () async {
    replies['/auth/native/recovery/email/complete-code'] = (status: 200, body: {});
    replies['/auth/native/recovery/email/complete-begin'] = (
      status: 200,
      body: begun(),
    );
    replies['/auth/native/recovery/email/complete-finish'] = (
      status: 200,
      body: {'status': 'completed'},
    );
    final r = make();
    await r.sendCompletionCode('a@b.co');
    await r.complete('a@b.co', 'ABCD2345');
    expect(creator.calls, 1);
    final fin = sent.last;
    expect(fin.$1, '/auth/native/recovery/email/complete-finish');
    expect(fin.$2['grant'], _tok('G'));
    expect(fin.$2['token'], _tok('C'));
    expect((fin.$2['response'] as Map)['id'], 'i');
    // the code is consumed: a retry needs a fresh one
    await expectLater(r.complete('a@b.co', 'ABCD2345'), throwsFormatException);
  });

  test('cancelled passkey sends no finish and keeps nothing', () async {
    creator = _Create(null);
    replies['/auth/native/recovery/email/complete-code'] = (status: 200, body: {});
    replies['/auth/native/recovery/email/complete-begin'] = (
      status: 200,
      body: begun(),
    );
    final r = make();
    await r.sendCompletionCode('a@b.co');
    await expectLater(r.complete('a@b.co', 'ABCD2345'), throwsStateError);
    expect(sent.any((e) => e.$1.endsWith('complete-finish')), isFalse);
  });

  test(
    'finish outcomes: 5xx, network loss, odd body are unknown; 4xx refused',
    () async {
      Future<Object?> run(
        ({int status, Map<String, dynamic>? body})? fin,
      ) async {
        replies = {
          '/auth/native/recovery/email/complete-code': (status: 200, body: {}),
          '/auth/native/recovery/email/complete-begin': (status: 200, body: begun()),
          '/auth/native/recovery/email/complete-finish': ?fin,
        };
        final r = make();
        await r.sendCompletionCode('a@b.co');
        try {
          await r.complete('a@b.co', 'ABCD2345');
          return null;
        } catch (e) {
          return e;
        }
      }

      expect(
        await run((status: 503, body: null)),
        isA<RecoveryOutcomeUnknown>(),
      );
      expect(await run(null), isA<RecoveryOutcomeUnknown>());
      expect(
        await run((status: 200, body: {'status': 'x'})),
        isA<RecoveryOutcomeUnknown>(),
      );
      expect(await run((status: 400, body: null)), isA<RecoveryRefused>());
    },
  );

  test('a ceremony for another rp is rejected before any prompt', () async {
    final b = begun();
    ((b['ceremony'] as Map)['options'] as Map)['rp'] = {
      'id': 'evil.example',
      'name': 'OTPanda',
    };
    replies['/auth/native/recovery/email/complete-code'] = (status: 200, body: {});
    replies['/auth/native/recovery/email/complete-begin'] = (status: 200, body: b);
    final r = make();
    await r.sendCompletionCode('a@b.co');
    await expectLater(
      r.complete('a@b.co', 'ABCD2345'),
      throwsA(isA<PasskeyException>()),
    );
    expect(creator.calls, 0);
  });
}
