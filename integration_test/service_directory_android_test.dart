// UNRUN on a device by its author (no Android SDK where this was written).
// Run with tool/android-directory-cache.sh on an emulator or device that has
// internet access.
//
// Acceptance for the cached 2FA Directory catalogue and logos on Android:
// the REAL path_provider plugin (getApplicationCacheDirectory) and the REAL
// network to api.2fa.directory and raw.githubusercontent.com, then a cold new
// directory from the files on disk with the network blocked, then the bounds.
// No account, no secrets and no app server are involved.
// NOT covered: hardware, iOS, browser/CORS, or the signed-in app pages.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/directory_store.dart';
import 'package:otpanda_client/public_service_catalog.dart';
import 'package:otpanda_client/service_directory.dart';
import 'package:otpanda_client/service_logo.dart';
import 'package:path_provider/path_provider.dart';

class _Blocked extends http.BaseClient {
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    calls++;
    throw http.ClientException('network blocked by the test');
  }
}

final _shotKey = GlobalKey();

Future<void> _settle(WidgetTester t, {int rounds = 15}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 300));
  final b =
      _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await t.runAsync(() async {
    final img = await b.toImage(pixelRatio: 1);
    final d = await img.toByteData(format: ui.ImageByteFormat.png);
    return d!.buffer.asUint8List();
  });
  expect(bytes!.length, greaterThan(2000), reason: 'blank screenshot $name');
  final s = base64Encode(bytes);
  const n = 800;
  final parts = (s.length / n).ceil();
  for (var i = 0; i < parts; i++) {
    // ignore: avoid_print
    print(
      'SHOTPART:$name:$i:$parts:${s.substring(i * n, (i + 1) * n > s.length ? s.length : (i + 1) * n)}',
    );
  }
}

Future<Directory> _cacheDir() async {
  final base = await getApplicationCacheDirectory();
  return Directory('${base.path}${Platform.pathSeparator}service-directory');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('catalogue and logos: network, cold disk, picker, bounds', (
    t,
  ) async {
    final dir = await _cacheDir();
    if (await dir.exists()) await dir.delete(recursive: true);

    // 1. Online, real plugin store, real network.
    final online = ServiceDirectory();
    await t.runAsync(online.ensureLoaded);
    expect(online.source, 'network', reason: 'needs internet on the device');
    expect(online.services.length, greaterThan(2000));
    final gh = online.resolve(serviceId: 'github.com', name: 'x')!;
    expect(gh.icon, 'github.com.svg');
    expect(gh.hosts.first, 'github.com');
    final logo = await t.runAsync(() => online.logo(gh.icon));
    expect(logo, isNotNull);
    expect(logo!.kind, LogoKind.svg);
    final files = await dir.list().map((e) => e.uri.pathSegments.last).toList();
    expect(files, containsAll(['catalog.json', 'logo-github.com.svg']));
    expect(files.where((f) => f.endsWith('.tmp')), isEmpty);
    expect(
      File('${dir.path}/catalog.json').lengthSync(),
      lessThan(DirectoryLimits.catalogBytes),
    );
    final rowsOnline = online.services.length;

    // 2. Cold new directory, same disk, network blocked.
    final blocked = _Blocked();
    final cold = ServiceDirectory(client: () => blocked);
    await t.runAsync(cold.ensureLoaded);
    expect(cold.source, 'cache');
    expect(cold.services.length, rowsOnline);
    final renamed = cold.resolve(
      serviceId: 'github.com',
      name: 'Totally renamed label',
    );
    expect(renamed?.icon, 'github.com.svg');
    final fromDisk = await t.runAsync(() => cold.logo('github.com.svg'));
    expect(fromDisk!.kind, LogoKind.svg);
    expect(fromDisk.bytes, logo.bytes);
    expect(blocked.calls, 0, reason: 'fresh catalogue and logo come from disk');

    t.view.physicalSize = const Size(900, 1400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: _shotKey,
            child: Container(
              color: Colors.white,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ServiceAvatar(
                    service: 'Totally renamed label',
                    serviceId: 'github.com',
                    color: Colors.green,
                    ink: Colors.black,
                    directory: cold,
                  ),
                  SizedBox(
                    height: 420,
                    child: PublicServicePicker(directory: cold),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(t);
    expect(find.byType(SvgPicture), findsWidgets);
    await t.enterText(find.byType(TextField), 'github');
    await _settle(t);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.byType(SvgPicture), findsAtLeastNWidgets(2));
    await _shot(t, 'cold-disk-renamed-avatar-and-picker');
    expect(blocked.calls, 0);

    // 3. Damaged catalogue on disk is ignored; the bundled snapshot is used.
    await File('${dir.path}/catalog.json').writeAsString('{broken');
    final damaged = ServiceDirectory(client: () => _Blocked());
    await t.runAsync(damaged.ensureLoaded);
    expect(damaged.source, 'bundled');
    expect(damaged.services, isNotEmpty);

    // 4. Bounds on the real file system. Unsafe keys never touch disk.
    final store = createDirectoryStore()!;
    await expectLater(
      store.write('../escape', Uint8List.fromList([1])),
      throwsArgumentError,
    );
    await expectLater(store.read('a/b'), throwsArgumentError);
    expect(File('${dir.parent.path}/escape').existsSync(), false);
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>';
    final filler = ServiceDirectory(
      store: store,
      client: () => MockClient(
        (_) async =>
            http.Response(svg, 200, headers: {'content-type': 'image/svg+xml'}),
      ),
    );
    for (var i = 0; i < DirectoryLimits.logoEntries + 20; i++) {
      await t.runAsync(() => filler.logo('bound$i.svg'));
    }
    final after = (await store.list()).where((e) => e.key.startsWith('logo-'));
    expect(after.length, lessThanOrEqualTo(DirectoryLimits.logoEntries));
    expect(
      after.fold<int>(0, (n, e) => n + e.size),
      lessThanOrEqualTo(DirectoryLimits.logoStoreBytes),
    );
    final names = await dir.list().map((e) => e.uri.pathSegments.last).toList();
    expect(names.where((n) => n.contains('/') || n.endsWith('.tmp')), isEmpty);
    await dir.delete(recursive: true);
  });
}
