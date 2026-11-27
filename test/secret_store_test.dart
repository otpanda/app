import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';

void main() {
  Uint8List b(List<int> v) => Uint8List.fromList(v);
  Matcher storeError(SecretStoreError e, {bool unknown = false}) =>
      isA<SecretStoreException>()
          .having((x) => x.error, 'error', e)
          .having((x) => x.outcomeUnknown, 'outcomeUnknown', unknown);

  test('absent reads null; create returns a copy', () async {
    final s = FakeSecretStore();
    expect(await s.read('k'), isNull);
    final v = b([1, 2, 3]);
    final stored = await s.createIfAbsent('k', v);
    v[0] = 9;
    stored[1] = 8;
    expect(await s.read('k'), [1, 2, 3]);
  });

  test('createIfAbsent never overwrites and returns the winner', () async {
    final s = FakeSecretStore();
    await s.createIfAbsent('k', b([1]));
    final r = await s.createIfAbsent('k', b([2]));
    expect(r, [1]);
    expect(await s.read('k'), [1]);
    expect(s.creates, 1);
  });

  test('known-failed create changes nothing', () async {
    final s = FakeSecretStore()..failNextCreate = SecretStoreError.locked;
    await expectLater(
      s.createIfAbsent('k', b([1])),
      throwsA(storeError(SecretStoreError.locked)),
    );
    expect(await s.read('k'), isNull);
  });

  test(
    'unknown-outcome create may have landed; caller must read back',
    () async {
      final s = FakeSecretStore()
        ..failNextCreate = SecretStoreError.unavailable
        ..failureOutcomeUnknown = true
        ..applyFailedMutation = true;
      await expectLater(
        s.createIfAbsent('k', b([5])),
        throwsA(storeError(SecretStoreError.unavailable, unknown: true)),
      );
      expect(await s.read('k'), [5]);
      // The same candidate retried returns the landed winner, not a second key.
      expect(await s.createIfAbsent('k', b([6])), [5]);
    },
  );

  test('unknown-outcome delete may have landed', () async {
    final s = FakeSecretStore();
    await s.createIfAbsent('k', b([1]));
    s
      ..failNextDelete = SecretStoreError.locked
      ..failureOutcomeUnknown = true
      ..applyFailedMutation = true;
    await expectLater(
      s.delete('k'),
      throwsA(storeError(SecretStoreError.locked, unknown: true)),
    );
    expect(await s.read('k'), isNull);
  });

  test('known-failed delete keeps the value; absent delete succeeds', () async {
    final s = FakeSecretStore();
    await s.createIfAbsent('k', b([1]));
    s.failNextDelete = SecretStoreError.unavailable;
    await expectLater(
      s.delete('k'),
      throwsA(storeError(SecretStoreError.unavailable)),
    );
    expect(await s.read('k'), [1]);
    await s.delete('k');
    await s.delete('k');
    expect(await s.read('k'), isNull);
  });

  test('corrupt is never absence and create does not replace it', () async {
    final s = FakeSecretStore();
    await s.createIfAbsent('k', b([1]));
    s.corruptNames.add('k');
    await expectLater(
      s.read('k'),
      throwsA(storeError(SecretStoreError.corrupt)),
    );
    await expectLater(
      s.createIfAbsent('k', b([2])),
      throwsA(storeError(SecretStoreError.corrupt)),
    );
    expect(s.creates, 1);
  });

  test('failAll never reports absence', () async {
    final s = FakeSecretStore()..failAll = SecretStoreError.locked;
    await expectLater(
      s.read('k'),
      throwsA(storeError(SecretStoreError.locked)),
    );
  });

  test(
    'known failures never apply even with stale failure injection',
    () async {
      final s = FakeSecretStore()
        ..applyFailedMutation = true
        ..failureOutcomeUnknown = false
        ..failNextCreate = SecretStoreError.unavailable;
      await expectLater(
        s.createIfAbsent('key', b([1])),
        throwsA(isA<SecretStoreException>()),
      );
      expect(await s.read('key'), isNull);
      await s.createIfAbsent('key', b([2]));
      s.failNextDelete = SecretStoreError.unavailable;
      await expectLater(s.delete('key'), throwsA(isA<SecretStoreException>()));
      expect(await s.read('key'), [2]);
    },
  );

  test('unknown create cannot overwrite a corrupt record', () async {
    final s = FakeSecretStore()
      ..corruptNames.add('key')
      ..applyFailedMutation = true
      ..failureOutcomeUnknown = true
      ..failNextCreate = SecretStoreError.unavailable;
    await expectLater(
      s.createIfAbsent('key', b([1])),
      throwsA(isA<SecretStoreException>()),
    );
    expect(s.names, isEmpty);
    await expectLater(s.read('key'), throwsA(isA<SecretStoreException>()));
  });

  test('error mapping keeps corruption distinct from missing', () {
    expect(custodyErrorNameFor(SecretStoreError.locked), 'locked');
    expect(custodyErrorNameFor(SecretStoreError.corrupt), 'tamper');
    expect(custodyErrorNameFor(SecretStoreError.denied), 'unavailable');
    expect(custodyErrorNameFor(SecretStoreError.unavailable), 'unavailable');
  });
}
