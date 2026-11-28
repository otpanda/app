import 'package:flutter_test/flutter_test.dart';

import 'package:otpanda_client/import_recovery_journal.dart';

class Journal implements ImportJournal {
  ImportAttempt? value;
  bool fail = false;
  @override
  Future<ImportAttempt?> read() async {
    if (fail) throw Exception();
    return value;
  }

  @override
  Future<bool> claim(ImportAttempt r) async {
    if (fail) throw Exception();
    if (value != null) return false;
    value = r;
    return true;
  }

  @override
  Future<bool> replace(ImportAttempt r, ImportAttempt next) async {
    if (fail) throw Exception();
    if (value?.encode() != r.encode()) return false;
    value = next;
    return true;
  }

  @override
  Future<bool> clear(ImportAttempt r) async {
    if (fail) throw Exception();
    if (value?.encode() != r.encode()) return false;
    value = null;
    return true;
  }
}

void main() {
  final rec = ImportAttempt(
    ownerId: 'owner',
    deviceId: 'device',
    nonce: 'v2:${'a' * 32}',
    admissionId: 'b' * 32,
    count: 2,
  );
  late Journal journal;
  late bool current;
  late int posts;
  late Map<String, dynamic> response;
  ImportRecoveryBarrier barrier({
    String owner = 'owner',
    String device = 'device',
  }) => ImportRecoveryBarrier(
    journal: journal,
    ownerId: owner,
    deviceId: device,
    current: () async => current,
    fence: (body) async {
      posts++;
      return (status: 200, body: response);
    },
  );
  setUp(() {
    journal = Journal();
    current = true;
    posts = 0;
    response = {'status': 'fenced'};
  });
  test('strict minimal schema roundtrip and redacted diagnostics', () {
    expect(ImportAttempt.decode(rec.encode())?.encode(), rec.encode());
    expect(
      ImportAttempt.decode(
        rec.encode().replaceFirst('"v":2', '"seed":"secret","v":2'),
      ),
      null,
    );
    expect(rec.toString(), 'ImportAttempt(redacted)');
  });
  test(
    'persisted before finish permission and process death blocks resend',
    () async {
      expect(await barrier().beforeFinish(rec), true);
      expect(journal.value?.nonce, rec.nonce);
      expect(await barrier().beforeFinish(rec), false);
      expect(posts, 0);
    },
  );
  test('unavailable persistence never grants finish', () async {
    journal.fail = true;
    await expectLater(barrier().beforeFinish(rec), throwsException);
    expect(posts, 0);
  });
  test('lock/session boundary blocks finish and reconcile', () async {
    current = false;
    expect(await barrier().beforeFinish(rec), false);
    journal.value = rec;
    expect(await barrier().reconcile(), ImportRecovery.unknown);
    expect(posts, 0);
  });
  test('restarted fenced outcome persists until acknowledged', () async {
    journal.value = rec;
    expect(await barrier().reconcile(), ImportRecovery.fenced);
    expect(journal.value?.outcome, 'fenced');
    expect(await barrier().reconcile(), ImportRecovery.fenced);
    expect(posts, 1);
    expect(await barrier().beforeFinish(rec), false);
    expect(await barrier().acknowledge(journal.value!), true);
    expect(journal.value, null);
  });
  test(
    'saved reply persists across restart with no second network send',
    () async {
      journal.value = rec;
      response = {
        'status': 'saved',
        'entryIds': ['one', 'two'],
      };
      expect(await barrier().reconcile(), ImportRecovery.saved);
      expect(await barrier().reconcile(), ImportRecovery.saved);
      expect(posts, 1);
      expect(journal.value?.outcome, 'saved');
    },
  );
  test('none is never terminal and pending cannot be acknowledged', () async {
    journal.value = rec;
    response = {'status': 'none'};
    expect(await barrier().reconcile(), ImportRecovery.unknown);
    expect(journal.value?.outcome, 'pending');
    expect(await barrier().acknowledge(rec), false);
  });
  test('malformed saved duplicate IDs stays unknown', () async {
    journal.value = rec;
    response = {
      'status': 'saved',
      'entryIds': ['one', 'one'],
    };
    expect(await barrier().reconcile(), ImportRecovery.unknown);
    expect(journal.value?.outcome, 'pending');
  });
  test('owner and device isolation no network, no delete', () async {
    journal.value = rec;
    expect(await barrier(owner: 'other').reconcile(), ImportRecovery.foreign);
    expect(await barrier(device: 'other').reconcile(), ImportRecovery.foreign);
    expect(posts, 0);
    expect(journal.value, rec);
  });
  test('no journal means nothing to reconcile', () async {
    expect(await barrier().reconcile(), ImportRecovery.nothing);
    expect(posts, 0);
  });
  test('clean success is durable and write failure stays unknown', () async {
    expect(await barrier().beforeFinish(rec), true);
    journal.fail = true;
    expect(
      await barrier().recordSaved(rec, ['one', 'two']),
      ImportRecovery.unknown,
    );
    journal.fail = false;
    expect(journal.value?.outcome, 'pending');
    expect(
      await barrier().recordSaved(rec, ['one', 'two']),
      ImportRecovery.saved,
    );
    expect(journal.value?.outcome, 'saved');
    expect(await barrier().reconcile(), ImportRecovery.saved);
    expect(posts, 0);
  });
  test(
    'lock after durable claim blocks finish but keeps recoverable attempt',
    () async {
      var checks = 0;
      final b = ImportRecoveryBarrier(
        journal: journal,
        ownerId: 'owner',
        deviceId: 'device',
        current: () async => ++checks == 1,
        fence: (body) async => (status: 200, body: response),
      );
      expect(await b.beforeFinish(rec), false);
      expect(journal.value?.outcome, 'pending');
      expect(await barrier().beforeFinish(rec), false);
      expect(await barrier().reconcile(), ImportRecovery.fenced);
    },
  );
  test(
    'protocol2 nonce total64 accepted, total65 rejected; no v1 fallback',
    () {
      ImportAttempt nonce(int n) => ImportAttempt(
        ownerId: 'owner',
        deviceId: 'device',
        nonce: 'v2:${'A' * n}',
        admissionId: 'B' * 32,
        count: 1,
      );
      expect(ImportAttempt.decode(nonce(61).encode()), isNotNull);
      expect(ImportAttempt.decode(nonce(62).encode()), isNull);
      expect(
        ImportAttempt.decode(rec.encode().replaceFirst('"v":2', '"v":1')),
        isNull,
      );
    },
  );
}
