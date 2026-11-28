import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/native/native_root_io.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/native/native_navigation.dart';

// Qualification only: mounted native UI uses the real API runtime over local
// stdio. Provider/picker, renewal entry and journal channels are synthetic.
// Widget recreation is not Android process death; no remote account is used.
class _Keys implements NativeKeystore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async =>
      Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
  @override
  Future<bool> hasPendingKey() async => false;
}

class _Store implements NativeSecureStore {
  @override
  Future<String?> readDeviceId() async => joinedDevice;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Browser implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _Google implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

String joinedDevice = '';
void main() {
  const enabled = bool.fromEnvironment('TOTP_IMPORT_ENABLED');
  setUpAll(() async {
    final loader = FontLoader('Figtree')
      ..addFont(
        File('assets/fonts/Figtree-400.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    await loader.load();
    final titleFont = FontLoader('BricolageGrotesque')
      ..addFont(
        File('assets/fonts/BricolageGrotesque-700.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      )
      ..addFont(
        File('assets/fonts/BricolageGrotesque-800.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    await titleFont.load();
    var flutterRoot = File(Platform.resolvedExecutable).parent;
    while (!File(
      '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    ).existsSync()) {
      if (flutterRoot.parent.path == flutterRoot.path) {
        throw StateError('Flutter icon font not found');
      }
      flutterRoot = flutterRoot.parent;
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await icons.load();
  });

  testWidgets(
    'mounted root joins real runtime receipt, widget recreation and fence',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      final m =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      late Process server;
      late Directory temporary;
      late StreamIterator<String> lines;
      Future<void> tail = Future.value();
      Object? rpcFailure;
      Future<Map<String, dynamic>> rpc(Map<String, dynamic> x) {
        final c = Completer<Map<String, dynamic>>();
        tail = tail.then((_) async {
          try {
            if (rpcFailure != null) throw StateError('RPC channel retired');
            server.stdin.writeln(jsonEncode(x));
            if (!await lines.moveNext().timeout(const Duration(seconds: 15))) {
              throw StateError('server ended');
            }
            final r = jsonDecode(lines.current) as Map<String, dynamic>;
            if (r['fixtureError'] == true) {
              throw StateError('unexpected fixture error');
            }
            c.complete(r);
          } catch (e, st) {
            rpcFailure = e;
            c.completeError(e, st);
            server.kill();
          }
        });
        return c.future.timeout(const Duration(seconds: 20));
      }

      final errors = <String>[];
      late Map<String, dynamic> hello;
      await t.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp(
          'otpanda-import-joined-',
        );
        server = await Process.start(
          'node',
          ['${Platform.environment['IMPORT_API_ROOT']}/tool/local-import-joined-stdio.mjs'],
          workingDirectory: Platform.environment['IMPORT_API_ROOT'],
          environment: {'TMPDIR': temporary.path, 'NODE_NO_WARNINGS': '1'},
        );
        addTearDown(() async {
          server.kill();
          await server.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              server.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
          if (await temporary.exists()) await temporary.delete(recursive: true);
        });
        server.stderr.transform(utf8.decoder).listen(errors.add);
        lines = StreamIterator(
          server.stdout.transform(utf8.decoder).transform(const LineSplitter()),
        );
        if (!await lines.moveNext().timeout(const Duration(seconds: 20))) {
          throw StateError('no runtime hello');
        }
        hello = jsonDecode(lines.current) as Map<String, dynamic>;
        joinedDevice = hello['deviceId'] as String;
      });

      Future<void> settle([bool Function()? ready]) async {
        for (var i = 0; i < 300; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 20));
          if (ready != null && ready()) return;
          if (ready == null && i >= 10 && !t.binding.hasScheduledFrame) return;
        }
        throw StateError('bounded UI/runtime await expired');
      }

      var picked = 0;
      String? journal;
      var begins = 0, finishes = 0;
      for (final name in [
        'app.otpanda/google',
        'app.otpanda/native',
        'app.otpanda/app-lock',
      ]) {
        m.setMockMethodCallHandler(MethodChannel(name), (c) async => false);
      }
      m.setMockMethodCallHandler(const MethodChannel('app.otpanda/passkey'), (
        c,
      ) async {
        if (c.method == 'available') return true;
        return jsonEncode(
          await rpc({
            'op': 'assert',
            'options': jsonDecode(
              (c.arguments as Map)['requestJson'] as String,
            ),
          }),
        );
      });
      m.setMockMethodCallHandler(
        const MethodChannel('app.otpanda/import-journal'),
        (c) async {
          if (c.method == 'read') return journal;
          final a = c.arguments as Map;
          if (c.method == 'claim') {
            if (journal != null) return false;
            journal = a['record'];
            return true;
          }
          if (c.method == 'replace') {
            if (journal != a['expected']) return false;
            journal = a['record'];
            return true;
          }
          if (c.method == 'clear') {
            journal = null;
            return true;
          }
          return null;
        },
      );
      m.setMockMethodCallHandler(
        const MethodChannel('app.otpanda/import-file'),
        (c) async => c.method == 'pickImportFile'
            ? 'otpauth://totp/Synthetic:a${++picked}?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Synthetic'
            : null,
      );
      final now = DateTime.now();
      final controller = NativeSessionController(
        NativeAuth(
          post: (p, b) async {
            return p.endsWith('challenge')
                ? (
                    status: 200,
                    body: <String, dynamic>{
                      'device_id': joinedDevice,
                      'nonce': 'n',
                      'expires_at': 5,
                    },
                  )
                : (
                    status: 200,
                    body: <String, dynamic>{
                      'access': hello['access'],
                      'access_expires_at': hello['expiresAt'],
                    },
                  );
          },
          keystore: _Keys(),
          browser: _Browser(),
          google: _Google(),
          store: _Store(),
          apiOrigin: 'https://example.invalid',
          launchUrl: (c, s) => Uri.parse('https://example.invalid'),
        ),
        clock: () => now,
      );
      final key = GlobalKey();
      var lostReply = true;
      Widget root() => RepaintBoundary(
        key: key,
        child: buildAndroidNativeRootForTest(
          session: controller,
          request: (method, path, {body, query, required bearer}) async {
            if (path.endsWith('batch-begin')) begins++;
            if (path.endsWith('batch-finish')) finishes++;
            if (lostReply && path.endsWith('batch-outcome')) {
              return const SessionResponse(503, '{}');
            }
            final r = await rpc({
              'path': path,
              'body': body == null ? null : jsonDecode(body),
            });
            if (lostReply && path.endsWith('batch-finish')) {
              return const SessionResponse(503, '{}');
            }
            return SessionResponse(r['status'] as int, r['body'] as String);
          },
        ),
      );
      await t.pumpWidget(root());
      await settle(() => find.byType(NativeNavigation).evaluate().isNotEmpty);
      final nav = t.widget<NativeNavigation>(find.byType(NativeNavigation));
      nav.history!.navigate('settings/transfer-codes');
      await settle(() => find.text('Import from file').evaluate().isNotEmpty);

      expect(find.text('Import from file'), findsOneWidget);
      await t.tap(find.text('Import from file'));
      await settle(() => find.text('Import 1 account').evaluate().isNotEmpty);
      expect(find.text('Import 1 account'), findsOneWidget);
      await capture(t, key, 'review');
      await t.tap(find.text('Import 1 account'));
      await settle(
        () => find.textContaining('could not confirm').evaluate().isNotEmpty,
      );
      expect(find.textContaining('could not confirm'), findsOneWidget);
      expect(journal, isNotNull);
      late Map<String, dynamic> counts;
      await t.runAsync(() async {
        counts = await rpc({'op': 'counts'});
      });
      expect(counts['entries'], 1);
      final trace = counts['trace'] as List;
      expect(
        trace.where(
          (x) =>
              x['path'].toString().endsWith('batch-finish') &&
              x['status'] == 201,
        ),
        hasLength(1),
      );
      expect(counts['totp_seeds'], 1);
      expect(counts['totp_batch_imports'], 1);
      await t.pumpWidget(const SizedBox.shrink());
      await settle();
      lostReply = false;
      await t.pumpWidget(root());
      await settle(() => find.byType(NativeNavigation).evaluate().isNotEmpty);
      t
          .widget<NativeNavigation>(find.byType(NativeNavigation))
          .history!
          .navigate('settings/transfer-codes');
      await settle(
        () =>
            find.text('Your previous import was saved.').evaluate().isNotEmpty,
      );
      expect(find.text('Your previous import was saved.'), findsOneWidget);
      expect(find.text('Import from file'), findsNothing);
      expect(begins, 1);
      expect(finishes, 1);
      await capture(t, key, 'joined-recovered');
      await t.tap(find.text('Got it'));
      await settle(() => find.text('Import from file').evaluate().isNotEmpty);
      expect(journal, isNull);
      expect(find.text('Import from file'), findsOneWidget);
      await t.runAsync(() async {
        counts = await rpc({'op': 'counts'});
      });
      expect(counts['entries'], 1);
      expect(counts['totp_batch_imports'], 1);
      await t.runAsync(() async {
        await rpc({'op': 'fenceNext'});
      });
      await t.tap(find.text('Import from file'));
      await settle(() => find.text('Import 1 account').evaluate().isNotEmpty);
      await t.tap(find.text('Import 1 account'));
      await settle(
        () => find
            .text('Nothing was saved. You can try again.')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.text('Nothing was saved. You can try again.'),
        findsOneWidget,
      );
      await t.runAsync(() async {
        counts = await rpc({'op': 'counts'});
        final late = await rpc({'op': 'lateFinish'});
        expect(late['status'], 409);
      });
      expect(counts['entries'], 1);
      expect(counts['totp_seeds'], 1);
      expect(counts['totp_batch_imports'], 1);
      expect(begins, 2);
      expect(finishes, 2);
      await capture(t, key, 'joined-fenced');
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump();
      controller.dispose();
      await t.runAsync(() async {
        await rpc({'op': 'shutdown'});
        expect(
          await server.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: errors.join(),
        );
        expect(errors, isEmpty);
        expect(rpcFailure, isNull);
        await lines.cancel();
      });
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    },
    skip:
        !enabled ||
        !const bool.fromEnvironment('IMPORT_JOINED_RUNTIME') ||
        Platform.environment['IMPORT_API_ROOT'] == null,
  );
}

Future<void> capture(WidgetTester t, GlobalKey k, String name) async {
  await t.runAsync(() async {
    final image =
        await (k.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final b = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/test-evidence')..createSync(recursive: true);
    await File('${dir.path}/import-current-root-$name.png')
        .writeAsBytes(b!.buffer.asUint8List());
    image.dispose();
  });
}
