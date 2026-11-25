import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:otpanda_client/directory_store.dart';
import 'package:otpanda_client/public_service_catalog.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/service_directory.dart';
import 'package:otpanda_client/service_logo.dart';

class MemStore implements DirectoryStore {
  final m = <String, Uint8List>{};
  final t = <String, int>{};
  var clock = 1000;
  bool failWrites = false;
  @override
  Future<Uint8List?> read(String key) async => m[key];
  @override
  Future<void> write(String key, Uint8List b) async {
    if (failWrites) throw StateError('quota');
    m[key] = b;
    t[key] = clock++;
  }

  @override
  Future<void> delete(String key) async {
    m.remove(key);
    t.remove(key);
  }

  @override
  Future<List<StoredItem>> list() async => [
    for (final k in m.keys) StoredItem(k, m[k]!.length, t[k] ?? 0),
  ];
}

const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#e00"/></svg>';
final catalog = jsonEncode([
  [
    'Github',
    {
      'domain': 'github.com',
      'tfa': ['totp'],
      'additional-domains': ['gist.github.com'],
    },
  ],
  [
    'Apple',
    {'domain': 'appleid.apple.com', 'img': 'apple.com.svg'},
  ],
  [
    'Twin',
    {'domain': 'twin-a.com'},
  ],
  [
    'twin',
    {'domain': 'twin-b.com'},
  ],
]);

Uint8List png(int w, int h) {
  final b = ByteData(33);
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (var i = 0; i < 8; i++) {
    b.setUint8(i, sig[i]);
  }
  b.setUint32(8, 13);
  for (var i = 0; i < 4; i++) {
    b.setUint8(12 + i, 'IHDR'.codeUnitAt(i));
  }
  b.setUint32(16, w);
  b.setUint32(20, h);
  return b.buffer.asUint8List();
}

http.Response okSvg(String body, [String type = 'image/svg+xml']) =>
    http.Response(body, 200, headers: {'content-type': type});

Future<String> noBundle() async => throw StateError('no bundle');

void main() {
  group('upstream catalogue parsing', () {
    test('keeps primary and additional domains, icon default and override', () {
      final rows = parseUpstreamCatalog(catalog);
      expect(rows[0].hosts, ['github.com', 'gist.github.com']);
      expect(rows[0].icon, 'github.com.svg');
      expect(rows[1].icon, 'apple.com.svg');
    });
    test('skips bad rows, rejects empty, oversize and wrong shape', () {
      final rows = parseUpstreamCatalog(
        jsonEncode([
          [
            'ok',
            {'domain': 'ok.com'},
          ],
          [
            'bad host',
            {'domain': 'http://evil'},
          ],
          [
            '',
            {'domain': 'blank.com'},
          ],
          [
            'ctl\u202e',
            {'domain': 'rtl.com'},
          ],
          [
            'trav',
            {'domain': 'trav.com', 'img': '../../x.svg'},
          ],
          [1, {}],
          'junk',
        ]),
      );
      expect(rows.map((r) => r.name), ['ok', 'trav']);
      expect(rows.last.icon, '');
      expect(() => parseUpstreamCatalog('[]'), throwsFormatException);
      expect(() => parseUpstreamCatalog('{}'), throwsFormatException);
      expect(
        () => parseUpstreamCatalog(' ' * (2 * 1024 * 1024 + 1)),
        throwsFormatException,
      );
    });
    test('icon names cannot traverse or change type', () {
      for (final bad in [
        '../a.svg',
        'a/b.svg',
        '.hidden.svg',
        'a.svg.exe',
        'a b.svg',
        '',
      ]) {
        expect(isValidIconName(bad), false, reason: bad);
      }
      expect(isValidIconName('github.com.svg'), true);
      expect(isValidIconName('x.png'), true);
    });
  });

  group('catalogue load and cache', () {
    test('network fills cache; fresh cache means no second request', () async {
      final store = MemStore();
      var calls = 0;
      final now = DateTime.utc(2026, 1, 1);
      http.Client c() => MockClient((r) async {
        calls++;
        expect(r.url.toString(), directoryCatalogUrl);
        expect(r.headers.containsKey('cookie'), false);
        return http.Response(catalog, 200, headers: {'etag': 'W/"1"'});
      });
      final a = ServiceDirectory(
        client: c,
        store: store,
        now: () => now,
        bundledText: noBundle,
      );
      await a.ensureLoaded();
      expect(a.source, 'network');
      expect(calls, 1);
      expect(a.lookup('  GITHUB ')!.hosts, ['github.com', 'gist.github.com']);
      final b = ServiceDirectory(
        client: c,
        store: store,
        now: () => now.add(const Duration(days: 6)),
        bundledText: noBundle,
      );
      await b.ensureLoaded();
      expect(b.source, 'cache');
      expect(calls, 1);
    });
    test(
      'stale cache sends If-None-Match; 304 keeps cache and restamps',
      () async {
        final store = MemStore();
        final t0 = DateTime.utc(2026, 1, 1);
        await (ServiceDirectory(
          client: () => MockClient(
            (_) async => http.Response(catalog, 200, headers: {'etag': 'E1'}),
          ),
          store: store,
          now: () => t0,
          bundledText: noBundle,
        )).ensureLoaded();
        String? inm;
        final t1 = t0.add(const Duration(days: 8));
        final d = ServiceDirectory(
          client: () => MockClient((r) async {
            inm = r.headers['if-none-match'];
            return http.Response('', 304);
          }),
          store: store,
          now: () => t1,
          bundledText: noBundle,
        );
        await d.ensureLoaded();
        expect(inm, 'E1');
        expect(d.source, 'cache');
        expect(d.fetchedAtMs, t1.millisecondsSinceEpoch);
        expect(d.lookup('github'), isNotNull);
      },
    );
    test(
      'refresh failure keeps last good cache; bad new file never replaces it',
      () async {
        final store = MemStore();
        final t0 = DateTime.utc(2026, 1, 1);
        await (ServiceDirectory(
          client: () => MockClient((_) async => http.Response(catalog, 200)),
          store: store,
          now: () => t0,
          bundledText: noBundle,
        )).ensureLoaded();
        final good = store.m['catalog.json']!;
        final later = t0.add(const Duration(days: 30));
        for (final h in <Future<http.Response> Function(http.Request)>[
          (_) async => throw http.ClientException('offline'),
          (_) async => http.Response('boom', 500),
          (_) async => http.Response('{"not":"a list"}', 200),
          (_) async => http.Response('[]', 200),
        ]) {
          final d = ServiceDirectory(
            client: () => MockClient(h),
            store: store,
            now: () => later,
            bundledText: noBundle,
          );
          await d.ensureLoaded();
          expect(d.source, 'cache');
          expect(d.lookup('github'), isNotNull);
          expect(store.m['catalog.json'], good);
        }
      },
    );
    test('oversize or slow catalogue response is dropped', () async {
      final big = ' ' * (2 * 1024 * 1024 + 10);
      final d = ServiceDirectory(
        client: () => MockClient((_) async => http.Response(big, 200)),
        store: MemStore(),
        bundledText: noBundle,
      );
      await d.ensureLoaded();
      expect(d.services, isEmpty);
      expect(d.loaded, true);
    });
    test('no cache and offline falls back to the bundled snapshot; corrupt cache is ignored', () async {
      final store = MemStore()
        ..m['catalog.json'] = Uint8List.fromList(utf8.encode('{broken'));
      final bundled = jsonEncode({
        'source': 'https://api.2fa.directory/v3/all.json',
        'license': 'MIT',
        'attribution': 'Data sourced from 2FA Directory by 2factorauth.',
        'signatureVerified': false,
        'fetchedAt': 1,
        'sha256': 'a' * 64,
        'services': [
          {'id': 'github.com', 'name': 'GitHub', 'host': 'github.com'},
        ],
      });
      final d = ServiceDirectory(
        client: () =>
            MockClient((_) async => throw http.ClientException('offline')),
        store: store,
        bundledText: () async => bundled,
      );
      await d.ensureLoaded();
      expect(d.source, 'bundled');
      expect(d.lookup('github')!.icon, 'github.com.svg');
    });
    test(
      'lookup is exact: no substring, ambiguous names resolve to nothing',
      () async {
        final d = ServiceDirectory(
          client: () => MockClient((_) async => http.Response(catalog, 200)),
          store: MemStore(),
          bundledText: noBundle,
        );
        await d.ensureLoaded();
        expect(d.lookup('Git'), isNull);
        expect(d.lookup('GitHub Enterprise'), isNull);
        expect(d.lookup('twin'), isNull);
        expect(d.lookup('apple')!.icon, 'apple.com.svg');
        expect(d.lookup(null), isNull);
        expect(d.lookup(''), isNull);
      },
    );
  });

  group('logo validation', () {
    test('accepts a plain svg and a small png', () {
      expect(
        validateLogo(Uint8List.fromList(utf8.encode(svg)))!.kind,
        LogoKind.svg,
      );
      expect(validateLogo(png(64, 64))!.kind, LogoKind.png);
    });
    test('refuses active content, external references and oversize', () {
      Uint8List s(String x) => Uint8List.fromList(utf8.encode(x));
      for (final bad in [
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg" onload="x()"></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><foreignObject/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><image href="https://e.test/a.png"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><use href="https://e.test/a.svg#x"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:url(https://e.test/x)"/></svg>',
        '<svg xmlns="http://www.w3.org/2000/svg"><style>@import "https://e.test/a.css";</style></svg>',
        '<!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="http://www.w3.org/2000/svg"/>',
        '<html><body>not an svg</body></html>',
        'plain text',
      ]) {
        expect(validateLogo(s(bad)), isNull, reason: bad);
      }
      expect(validateLogo(Uint8List(0)), isNull);
      expect(
        validateLogo(
          s('<svg xmlns="http://www.w3.org/2000/svg">${' ' * 70000}</svg>'),
        ),
        isNull,
      );
      expect(
        validateLogo(
          s('<svg xmlns="http://www.w3.org/2000/svg">${'<g/>' * 1600}</svg>'),
        ),
        isNull,
      );
      expect(
        validateLogo(Uint8List.fromList([0xff, 0xfe, 0x3c, 0x73])),
        isNull,
      );
      expect(validateLogo(png(4000, 4000)), isNull);
      expect(validateLogo(png(0, 10)), isNull);
    });
    test('an internal fragment reference still renders', () {
      expect(
        validateLogo(
          Uint8List.fromList(
            utf8.encode(
              '<svg xmlns="http://www.w3.org/2000/svg"><defs><g id="a"><rect width="1" height="1"/></g></defs><use href="#a"/></svg>',
            ),
          ),
        ),
        isNotNull,
      );
    });
  });

  group('logo fetch and cache', () {
    ServiceDirectory dir(
      Future<http.Response> Function(http.Request) h, {
      MemStore? store,
      DateTime Function()? now,
    }) => ServiceDirectory(
      client: () => MockClient(h),
      store: store ?? MemStore(),
      now: now,
      bundledText: noBundle,
    );

    test(
      'fetches from the repo icon path, caches, then serves with no network',
      () async {
        final store = MemStore();
        final urls = <String>[];
        final a = dir((r) async {
          urls.add(r.url.toString());
          expect(r.headers.keys.where((k) => k != 'user-agent'), isEmpty);
          return okSvg(svg);
        }, store: store);
        final l = await a.logo('github.com.svg');
        expect(l!.kind, LogoKind.svg);
        expect(urls, ['${directoryIconBase}g/github.com.svg']);
        final b = dir(
          (_) async => throw http.ClientException('offline'),
          store: store,
        );
        expect((await b.logo('github.com.svg'))!.kind, LogoKind.svg);
      },
    );
    test('refuses wrong type, mismatched type, bad status, oversize body, bad names', () async {
      var n = 0;
      final d = dir((r) async {
        n++;
        final f = r.url.pathSegments.last;
        switch (f) {
          case 'html.svg':
            return okSvg(svg, 'text/html');
          case 'mismatch.png':
            return okSvg(svg, 'image/png');
          case 'missing.svg':
            return http.Response('nope', 404);
          case 'big.svg':
            return okSvg('<svg xmlns="x">${' ' * 70000}</svg>');
        }
        return okSvg(svg);
      });
      for (final f in ['html.svg', 'mismatch.png', 'missing.svg', 'big.svg']) {
        expect(await d.logo(f), isNull, reason: f);
      }
      final before = n;
      for (final f in ['../../etc.svg', 'a/b.svg', 'noext', '']) {
        expect(await d.logo(f), isNull);
      }
      expect(n, before, reason: 'invalid names never reach the network');
    });
    test('a declared or streamed size over the cap stops the read', () async {
      final big = MockClient.streaming(
        (r, _) async => http.StreamedResponse(
          Stream.fromIterable([Uint8List(40000), Uint8List(40000)]),
          200,
          headers: {'content-type': 'image/svg+xml'},
        ),
      );
      final d = ServiceDirectory(
        client: () => big,
        store: MemStore(),
        bundledText: noBundle,
      );
      expect(await d.logo('a.svg'), isNull);
      final declared = MockClient.streaming(
        (r, _) async => http.StreamedResponse(
          const Stream.empty(),
          200,
          contentLength: 999999,
          headers: {'content-type': 'image/svg+xml'},
        ),
      );
      final e = ServiceDirectory(
        client: () => declared,
        store: MemStore(),
        bundledText: noBundle,
      );
      expect(await e.logo('b.svg'), isNull);
    });
    test('failures back off for an hour, then retry', () async {
      var n = 0;
      var t = DateTime.utc(2026, 1, 1);
      final d = dir((_) async {
        n++;
        return http.Response('', 404);
      }, now: () => t);
      await d.logo('x.svg');
      await d.logo('x.svg');
      expect(n, 1);
      t = t.add(const Duration(minutes: 61));
      await d.logo('x.svg');
      expect(n, 2);
    });
    test('stale cached logo is kept when the refresh fails', () async {
      final store = MemStore();
      final t0 = DateTime.now();
      await dir(
        (_) async => okSvg(svg),
        store: store,
        now: () => t0,
      ).logo('k.svg');
      store.t['logo-k.svg'] = t0
          .subtract(const Duration(days: 40))
          .millisecondsSinceEpoch;
      final d = dir(
        (_) async => throw http.ClientException('offline'),
        store: store,
        now: () => t0,
      );
      expect((await d.logo('k.svg'))!.kind, LogoKind.svg);
    });
    test('a poisoned cache entry is not trusted', () async {
      final store = MemStore()
        ..m['logo-p.svg'] = Uint8List.fromList(
          utf8.encode('<svg xmlns="x"><script/></svg>'),
        );
      final d = dir((_) async => http.Response('', 500), store: store);
      expect(await d.logo('p.svg'), isNull);
    });
    test(
      'at most 4 fetches run at once and a full store failing is harmless',
      () async {
        var live = 0, peak = 0;
        final gate = Completer<void>();
        final store = MemStore()..failWrites = true;
        final d = ServiceDirectory(
          client: () => MockClient((r) async {
            live++;
            if (live > peak) peak = live;
            await gate.future;
            live--;
            return okSvg(svg);
          }),
          store: store,
          bundledText: noBundle,
        );
        final futures = [for (var i = 0; i < 12; i++) d.logo('i$i.svg')];
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(peak, 4);
        gate.complete();
        final all = await Future.wait(futures);
        expect(all.every((e) => e != null), true);
        expect(peak, 4);
      },
    );
    test('duplicate requests share one fetch', () async {
      var n = 0;
      final d = dir((_) async {
        n++;
        return okSvg(svg);
      });
      await Future.wait([d.logo('s.svg'), d.logo('s.svg'), d.logo('s.svg')]);
      expect(n, 1);
    });
    test('store is bounded by entry count, oldest evicted first', () async {
      final store = MemStore();
      final d = dir((_) async => okSvg(svg), store: store);
      for (var i = 0; i < DirectoryLimits.logoEntries + 5; i++) {
        await d.logo('e$i.svg');
      }
      final logos = store.m.keys.where((k) => k.startsWith('logo-')).toList();
      expect(logos.length, DirectoryLimits.logoEntries);
      expect(store.m.containsKey('logo-e0.svg'), false);
      expect(
        store.m.containsKey('logo-e${DirectoryLimits.logoEntries + 4}.svg'),
        true,
      );
    });
  });

  group('ServiceAvatar', () {
    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 4; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> pump(WidgetTester t, ServiceDirectory d, String name) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ServiceAvatar(
                service: name,
                color: Colors.green,
                ink: Colors.black,
                directory: d,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('letter first, then the logo at the same size', (t) async {
      final gate = Completer<void>();
      final d = ServiceDirectory(
        client: () => MockClient((r) async {
          if (r.url.toString() == directoryCatalogUrl) {
            return http.Response(catalog, 200);
          }
          await gate.future;
          return okSvg(svg);
        }),
        store: MemStore(),
        bundledText: noBundle,
      );
      await t.runAsync(d.ensureLoaded);
      await pump(t, d, 'Github');
      expect(find.text('G'), findsOneWidget);
      expect(t.getSize(find.byType(ServiceAvatar)), const Size(36, 36));
      gate.complete();
      await settle(t);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.text('G'), findsNothing);
      expect(t.getSize(find.byType(ServiceAvatar)), const Size(36, 36));
    });

    testWidgets('unknown, ambiguous and failing logos stay as the letter', (
      t,
    ) async {
      final d = ServiceDirectory(
        client: () => MockClient(
          (r) async => r.url.toString() == directoryCatalogUrl
              ? http.Response(catalog, 200)
              : http.Response('', 404),
        ),
        store: MemStore(),
        bundledText: noBundle,
      );
      await t.runAsync(d.ensureLoaded);
      for (final n in ['Nothing Here', 'twin', 'Github']) {
        await pump(t, d, n);
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump();
        expect(find.text(n[0].toUpperCase()), findsOneWidget, reason: n);
        expect(find.byType(SvgPicture), findsNothing);
      }
    });

    testWidgets('a renderable-looking but broken svg falls back to the letter', (
      t,
    ) async {
      const broken =
          '<svg xmlns="http://www.w3.org/2000/svg"><path d="M 0 0 L"/><rect width="oops"/></svg>';
      final d = ServiceDirectory(
        client: () => MockClient(
          (r) async => r.url.toString() == directoryCatalogUrl
              ? http.Response(catalog, 200)
              : okSvg(broken),
        ),
        store: MemStore(),
        bundledText: noBundle,
      );
      await t.runAsync(d.ensureLoaded);
      await pump(t, d, 'Github');
      await settle(t);
      expect(t.takeException(), isNull);
      expect(find.byType(ServiceAvatar), findsOneWidget);
    });
  });

  group('persisted identity survives renaming', () {
    Future<ServiceDirectory> loaded() async {
      final d = ServiceDirectory(
        client: () => MockClient((_) async => http.Response(catalog, 200)),
        store: MemStore(),
        bundledText: noBundle,
      );
      await d.ensureLoaded();
      return d;
    }

    test('service id and host win over any label', () async {
      final d = await loaded();
      expect(
        d.resolve(serviceId: 'github.com', name: 'My work login')!.icon,
        'github.com.svg',
      );
      expect(d.resolve(host: 'github.com', name: 'x')!.icon, 'github.com.svg');
      expect(
        d.resolve(serviceId: 'appleid.apple.com', name: 'Renamed')!.icon,
        'apple.com.svg',
      );
    });
    test('identity beats a name that points somewhere else', () async {
      final d = await loaded();
      expect(
        d.resolve(serviceId: 'github.com', name: 'Apple')!.hosts.first,
        'github.com',
      );
    });
    test('custom, malformed, unknown, shared or additional-only ids fall back to the exact name', () async {
      final d = await loaded();
      for (final id in [
        'custom-totp',
        'GitHub.com',
        'github',
        'evil.test/x',
        '../x',
        'gist.github.com',
        'twin-a.com.evil.test',
        null,
      ]) {
        expect(
          d.resolve(serviceId: id, name: 'Github')!.hosts.first,
          'github.com',
          reason: '$id',
        );
        expect(
          d.resolve(serviceId: id, name: 'Renamed label'),
          isNull,
          reason: '$id',
        );
      }
    });
    test(
      'ManagedEntry keeps a plain host service_id and drops anything else',
      () {
        Map<String, dynamic> j(Object? id) => {
          'entry_id': 'e1',
          'service_name': 'GitHub',
          'account_name': 'a',
          'capabilities': {'manage': true},
          'service_id': id,
        };
        expect(ManagedEntry.fromJson(j('github.com')).serviceId, 'github.com');
        expect(ManagedEntry.fromJson(j('custom-totp')).serviceId, isNull);
        expect(ManagedEntry.fromJson(j('custom-totp')).totp, true);
        expect(ManagedEntry.fromJson(j('http://x')).serviceId, isNull);
        expect(ManagedEntry.fromJson(j(7)).serviceId, isNull);
      },
    );
    testWidgets('a renamed entry keeps its logo', (t) async {
      final d = ServiceDirectory(
        client: () => MockClient(
          (r) async => r.url.toString() == directoryCatalogUrl
              ? http.Response(catalog, 200)
              : okSvg(svg),
        ),
        store: MemStore(),
        bundledText: noBundle,
      );
      await t.runAsync(d.ensureLoaded);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServiceAvatar(
              service: 'Totally renamed',
              serviceId: 'github.com',
              color: Colors.green,
              ink: Colors.black,
              directory: d,
            ),
          ),
        ),
      );
      for (var i = 0; i < 4; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(SvgPicture), findsOneWidget);
    });
  });

  group('runtime catalogue feeds the picker', () {
    test(
      'directory rows pass the same id and name rules as the bundled file',
      () {
        expect(isPublicServiceId('github.com'), true);
        for (final bad in [
          '127.0.0.1',
          'a.local',
          'x.internal',
          '-a.com',
          'a-.com',
          'a',
          'A.com',
          'x' * 129,
        ]) {
          expect(isPublicServiceId(bad), false, reason: bad);
        }
        expect(isPublicServiceName('Okay'), true);
        expect(isPublicServiceName('bad\u202ename'), false);
        expect(isPublicServiceName(' '), false);
        final c = PublicServiceCatalog.fromDirectory(
          parseUpstreamCatalog(catalog),
          5,
        );
        expect(c.services.map((e) => e.id), [
          'github.com',
          'appleid.apple.com',
          'twin-a.com',
          'twin-b.com',
        ]);
        expect(c.services.first.host, 'github.com');
      },
    );
    testWidgets('the picker lists a service only the runtime catalogue has', (
      t,
    ) async {
      final d = ServiceDirectory(
        client: () => MockClient(
          (r) async => r.url.toString() == directoryCatalogUrl
              ? http.Response('[["Zzyzx Demo", {"domain": "zzyzx.test"}]]', 200)
              : http.Response('', 404),
        ),
        store: MemStore(),
        bundledText: noBundle,
      );
      await t.runAsync(d.ensureLoaded);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PublicServicePicker(directory: d)),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      await t.enterText(find.byType(TextField), 'zzyzx');
      for (var i = 0; i < 3; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Zzyzx Demo'), findsOneWidget);
      expect(find.text('zzyzx.test'), findsOneWidget);
    });
  });
}
