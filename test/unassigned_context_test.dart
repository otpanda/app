import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/unassigned_context.dart';

void main() {
  Map<String, dynamic> sample() => {
    'contextId': 'ctx',
    'sourceId': 'src',
    'eventId': 'event',
    'kind': 'sms',
    'sender': '+15555550123',
    'sourceLabel': 'Personal phone',
    'receivedAt': 1000,
    'arrivedAt': 1000,
    'retainedUntil': 1000 + 30 * 86400000,
    'redactedText': 'Your code is [redacted].',
    'contextUnavailable': false,
    'truncated': false,
  };
  test('separate review model never offers stale code and expires exactly', () {
    final c = UnassignedContext.fromJson(sample());
    expect(c.retained(999), false);
    expect(c.retained(1000), true);
    expect(c.retained(c.retainedUntil - 1), true);
    expect(c.retained(c.retainedUntil), false);
    expect(c.contentLabel, 'Message, code redacted');
    expect(c.toString(), 'UnassignedContext(redacted)');
  });
  test(
    'historical unavailable context is honest and has no fabricated text',
    () {
      final c = UnassignedContext.fromJson({
        ...sample(),
        'contextUnavailable': true,
        'redactedText': null,
      });
      expect(c.redactedText, null);
      expect(c.contextUnavailable, true);
    },
  );
  test('email label is subject only and byte caps are enforced', () {
    expect(
      UnassignedContext.fromJson({...sample(), 'kind': 'email'}).contentLabel,
      'Subject, code redacted',
    );
    expect(
      () => UnassignedContext.fromJson({
        ...sample(),
        'kind': 'email',
        'redactedText': 'א' * 513,
      }),
      throwsFormatException,
    );
  });
  test(
    'reject usable code fields, policy overflow and inconsistent context',
    () {
      for (final m in [
        {...sample(), 'code': '123456'},
        {...sample(), 'value': '123456'},
        {...sample(), 'retainedUntil': 1001 + 30 * 86400000},
        {...sample(), 'receivedAt': -1},
        {...sample(), 'contextUnavailable': true},
        {...sample(), 'redactedText': null},
        {...sample(), 'sender': 'sender\nother'},
        {...sample(), 'kind': 'untrusted'},
        {...sample(), 'truncated': 'false'},
      ]) {
        expect(() => UnassignedContext.fromJson(m), throwsFormatException);
      }
    },
  );
  test('server arrival controls retention, provider date is display only', () {
    final c = UnassignedContext.fromJson({...sample(), 'receivedAt': 0});
    expect(c.arrivedAt, 1000);
    expect(c.retained(999), false);
    expect(
      () => UnassignedContext.fromJson({...sample(), 'receivedAt': 1001}),
      throwsFormatException,
    );
    expect(
      () => UnassignedContext.fromJson({...sample(), 'arrivedAt': null}),
      throwsFormatException,
    );
  });
}
