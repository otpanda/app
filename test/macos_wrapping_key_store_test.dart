import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';
import 'package:otpanda_client/offline_totp/macos_wrapping_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/wrapping-key');
  final store = MacosWrappingKeyStore(channel);
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final calls = <MethodCall>[];

  void reply(Object? Function(MethodCall) f) {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return f(c);
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Matcher err(SecretStoreError e, {bool unknown = false}) =>
      isA<SecretStoreException>()
          .having((x) => x.error, 'error', e)
          .having((x) => x.outcomeUnknown, 'outcomeUnknown', unknown);

  test('read: absent is null, present is a 32-byte copy', () async {
    reply((_) => {'key': null});
    expect(await store.read('inst1'), isNull);
    reply((_) => {'key': key});
    expect(await store.read('inst1'), key);
    expect(calls.single.method, 'wrappingKeyRead');
    expect(calls.single.arguments, {'namespace': 'inst1'});
  });

  test('read: wrong size or shape is corrupt/unavailable, never absent', () async {
    reply((_) => {'key': Uint8List(31)});
    await expectLater(store.read('inst1'), throwsA(err(SecretStoreError.corrupt)));
    reply((_) => {'other': 1});
    await expectLater(
      store.read('inst1'),
      throwsA(err(SecretStoreError.unavailable)),
    );
    reply((_) => null);
    await expectLater(
      store.read('inst1'),
      throwsA(err(SecretStoreError.unavailable)),
    );
  });

  test('platform codes map without recovery semantics', () async {
    for (final (code, want) in [
      ('locked', SecretStoreError.locked),
      ('denied', SecretStoreError.denied),
      ('corrupt', SecretStoreError.corrupt),
      ('unavailable', SecretStoreError.unavailable),
      ('weird', SecretStoreError.unavailable),
    ]) {
      reply((_) => throw PlatformException(code: code));
      await expectLater(store.read('inst1'), throwsA(err(want)));
    }
  });

  test('missing plugin is unavailable', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(
      store.read('inst1'),
      throwsA(err(SecretStoreError.unavailable)),
    );
  });

  test('create: returns winner, sends exactly the candidate', () async {
    final winner = Uint8List.fromList(List<int>.filled(32, 9));
    reply((_) => {'key': winner, 'created': false});
    expect(await store.createIfAbsent('inst1', key), winner);
    expect(calls.single.method, 'wrappingKeyCreate');
    expect(calls.single.arguments, {'namespace': 'inst1', 'key': key});
  });

  test('create: unknown outcome flag is preserved; malformed reply is unknown', () async {
    reply((_) => throw PlatformException(
          code: 'unavailable',
          details: {'outcomeUnknown': true},
        ));
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
    reply((_) => throw PlatformException(
          code: 'unavailable',
          details: {'outcomeUnknown': false},
        ));
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable)),
    );
    reply((_) => throw PlatformException(code: 'nonsense'));
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
    reply((_) => {'key': key});
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
    reply((_) => {'key': Uint8List(5), 'created': true});
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
  });

  test('create: corrupt existing key is surfaced, not replaced', () async {
    reply((_) => throw PlatformException(
          code: 'corrupt',
          details: {'outcomeUnknown': false},
        ));
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.corrupt)),
    );
  });

  test('delete: success needs an empty map; failures preserve flags', () async {
    reply((_) => <String, Object?>{});
    await store.delete('inst1');
    reply((_) => {'x': 1});
    await expectLater(
      store.delete('inst1'),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
    reply((_) => throw PlatformException(
          code: 'denied',
          details: {'outcomeUnknown': true},
        ));
    await expectLater(
      store.delete('inst1'),
      throwsA(err(SecretStoreError.denied, unknown: true)),
    );
  });

  test('invalid names and candidate sizes never reach the channel', () async {
    reply((_) => {'key': null});
    for (final bad in ['', 'a/b', '..', 'a b', 'x' * 65]) {
      await expectLater(store.read(bad), throwsA(err(SecretStoreError.unavailable)));
    }
    await expectLater(
      store.createIfAbsent('inst1', Uint8List(31)),
      throwsA(err(SecretStoreError.unavailable)),
    );
    expect(calls, isEmpty);
  });

  test('mutation error details are strictly validated', () async {
    for (final details in <Object?>[
      null,
      'text',
      <String, Object?>{},
      {'outcomeUnknown': 'false'},
      {'outcomeUnknown': null},
      {'outcomeUnknown': false, 'extra': 1},
      {'other': false},
    ]) {
      reply((_) => throw PlatformException(code: 'denied', details: details));
      await expectLater(
        store.createIfAbsent('inst1', key),
        throwsA(err(SecretStoreError.denied, unknown: true)),
        reason: 'details $details',
      );
      reply((_) => throw PlatformException(code: 'corrupt', details: details));
      await expectLater(
        store.delete('inst1'),
        throwsA(err(SecretStoreError.corrupt, unknown: true)),
      );
    }
    reply((_) => throw PlatformException(
          code: 'denied',
          details: {'outcomeUnknown': false},
        ));
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.denied)),
    );
  });

  test('generic exceptions after a mutation starts mean unknown', () async {
    final broken = MacosWrappingKeyStore(const _ThrowingChannel());
    await expectLater(
      broken.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
    await expectLater(
      broken.delete('inst1'),
      throwsA(err(SecretStoreError.unavailable, unknown: true)),
    );
    // Reads are not mutations.
    await expectLater(
      broken.read('inst1'),
      throwsA(err(SecretStoreError.unavailable)),
    );
  });

  test('missing plugin on a mutation is known not applied', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.unavailable)),
    );
  });

  test('locked mutation with well-formed details is known not applied', () async {
    reply(
      (_) => throw PlatformException(
        code: 'locked',
        details: {'outcomeUnknown': false},
      ),
    );
    await expectLater(
      store.createIfAbsent('inst1', key),
      throwsA(err(SecretStoreError.locked)),
    );
    reply((_) => throw PlatformException(code: 'locked'));
    await expectLater(
      store.delete('inst1'),
      throwsA(err(SecretStoreError.locked, unknown: true)),
    );
  });
}

/// A channel whose codec layer fails with a generic (non-platform) exception.
final class _ThrowingChannel extends MethodChannel {
  const _ThrowingChannel() : super('test/throwing');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      Future<T?>.error(const FormatException('codec'));
}
