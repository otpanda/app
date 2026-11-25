@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otpanda_client/directory_store.dart';
import 'package:otpanda_client/service_directory.dart';

const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>';

void main() {
  test('web store round-trips bytes, lists and rejects unsafe keys', () async {
    final s = createDirectoryStore()!;
    await s.write('logo-a.svg', Uint8List.fromList([1, 2, 3]));
    expect(await s.read('logo-a.svg'), [1, 2, 3]);
    expect(
      (await s.list()).any((e) => e.key == 'logo-a.svg' && e.size > 0),
      true,
    );
    expect(await s.read('logo-missing.svg'), isNull);
    await expectLater(s.read('../x'), throwsArgumentError);
    await s.delete('logo-a.svg');
    expect(await s.read('logo-a.svg'), isNull);
  });

  test('catalogue and logo survive a new session with no network', () async {
    final store = createDirectoryStore()!;
    final first = ServiceDirectory(
      store: store,
      bundledText: () async => throw StateError('none'),
      client: () => MockClient((r) async {
        if (r.url.toString() == directoryCatalogUrl) {
          return http.Response('[["Demo", {"domain": "demo.test"}]]', 200);
        }
        return http.Response(
          svg,
          200,
          headers: {'content-type': 'image/svg+xml'},
        );
      }),
    );
    await first.ensureLoaded();
    expect(first.source, 'network');
    expect((await first.logo('demo.test.svg'))!.kind, LogoKind.svg);
    final offline = ServiceDirectory(
      store: store,
      bundledText: () async => throw StateError('none'),
      client: () =>
          MockClient((_) async => throw http.ClientException('offline')),
    );
    await offline.ensureLoaded();
    expect(offline.source, 'cache');
    expect(offline.lookup('demo')!.icon, 'demo.test.svg');
    expect((await offline.logo('demo.test.svg'))!.kind, LogoKind.svg);
    await store.delete('catalog.json');
    await store.delete('logo-demo.test.svg');
  });
}
