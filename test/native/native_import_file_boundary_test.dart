import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_root_io.dart';

void main() {
  test(
    'root drops selected document when identity changes during picker',
    () async {
      var current = true, calls = 0;
      final gate = Completer<String?>();
      final read = guardedImportFile(
        current: () async => current,
        pick: () {
          calls++;
          return gate.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      gate.complete('synthetic document');
      expect(await read, null);
      expect(calls, 1);
    },
  );
  test('root never opens picker while locked or retired', () async {
    var calls = 0;
    expect(
      await guardedImportFile(
        current: () async => false,
        pick: () async {
          calls++;
          return 'synthetic';
        },
      ),
      null,
    );
    expect(calls, 0);
  });
}
