import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/transfer/android_import_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('app.otpanda/import-file');
  late List<String> calls;
  late Future<Object?> Function(MethodCall) handler;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (c) {
          calls.add(c.method);
          return handler(c);
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null),
  );

  test('returns text, once, with no arguments', () async {
    Object? args = 1;
    handler = (c) async {
      args = c.arguments;
      return 'abc';
    };
    expect(await AndroidImportPicker().pick(), 'abc');
    expect(args, isNull);
    expect(calls, ['pickImportFile']);
  });

  test('null reply is cancellation', () async {
    handler = (_) async => null;
    expect(await AndroidImportPicker().pick(), isNull);
  });

  test('known codes map to typed errors', () async {
    for (final e in ImportPickerError.values) {
      handler = (_) async => throw PlatformException(code: e.name);
      await expectLater(
        AndroidImportPicker().pick(),
        throwsA(
          isA<ImportPickerException>().having((x) => x.error, 'error', e),
        ),
      );
    }
  });

  test(
    'unknown code, message, details and malformed replies are unavailable',
    () async {
      final bad = <Future<Object?> Function(MethodCall)>[
        (_) async => throw PlatformException(code: 'weird'),
        (_) async => throw PlatformException(code: 'tooLarge', message: 'x'),
        (_) async => throw PlatformException(code: 'tooLarge', details: 1),
        (_) async => 5,
        (_) async => <Object?, Object?>{'a': 1},
        (_) async => throw MissingPluginException(),
      ];
      for (final h in bad) {
        handler = h;
        await expectLater(
          AndroidImportPicker().pick(),
          throwsA(
            isA<ImportPickerException>().having(
              (x) => x.error,
              'error',
              ImportPickerError.unavailable,
            ),
          ),
        );
      }
    },
  );

  test('late reply after cancel is dropped', () async {
    final done = Completer<Object?>();
    handler = (c) =>
        c.method == 'pickImportFile' ? done.future : Future.value(null);
    final p = AndroidImportPicker();
    final f = p.pick();
    await p.cancel();
    done.complete('secret');
    expect(await f, isNull);
    expect(calls, ['pickImportFile', 'cancelImportFile']);
  });

  test('late error after cancel is dropped', () async {
    final done = Completer<Object?>();
    handler = (c) =>
        c.method == 'pickImportFile' ? done.future : Future.value(null);
    final p = AndroidImportPicker();
    final f = p.pick();
    await p.cancel();
    done.completeError(PlatformException(code: 'busy'));
    expect(await f, isNull);
  });

  test('cancel failures do not throw', () async {
    handler = (_) async => throw PlatformException(code: 'unavailable');
    await AndroidImportPicker().cancel();
  });
}
