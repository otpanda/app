import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/otpauth.dart';
import 'package:otpanda_client/qr_camera.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_enrollment.dart';

class _Bridge implements TotpManagementBridge {
  final adds = <List<String>>[];
  Completer<void>? gate;
  bool failNext = false;
  @override
  Future<String> addTotp(String label, String account, String secret) async {
    adds.add([label, account, secret]);
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('save failed');
    }
    return 'entry';
  }

  @override
  Future<SessionResponse> totpCode(String entryId) async =>
      const SessionResponse(200, '{}');
}

const _uri =
    'otpauth://totp/GitHub:bob%40example.test?secret=JBSWY3DPEHPK3PXP&issuer=GitHub';

// Pixel captures need local fonts and are only taken on request:
// GOLDENS=1 flutter test --update-goldens test/add_authenticator_flow_test.dart
final _shots = Platform.environment['GOLDENS'] == '1';
Future<void> _shot(String name) async {
  if (!_shots) return;
  await expectLater(
    find.byType(AlertDialog),
    matchesGoldenFile('goldens/$name.png'),
  );
}

Future<void> _fonts() async {
  if (!_shots) return;
  Future<void> load(String family, List<String> paths) async {
    final l = FontLoader(family);
    for (final p in paths) {
      l.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
    }
    await l.load();
  }

  await load('Figtree', [
    'assets/fonts/Figtree-400.ttf',
    'assets/fonts/Figtree-600.ttf',
  ]);
  await load('MaterialIcons', [
    '/tmp/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

void main() {
  late void Function(String) scan;
  late void Function(QrCameraProblem) problem;
  late int cameras, disposed;
  late _Bridge bridge;

  Widget fakeCamera(void Function(String) t, void Function(QrCameraProblem) p) {
    scan = t;
    problem = p;
    return _Fake(onInit: () => cameras++, onDispose: () => disposed++);
  }

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Figtree'),
        home: Builder(
          builder: (c) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => addTotpDialog(c, bridge, camera: fakeCamera),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  setUpAll(_fonts);
  setUp(() {
    cameras = 0;
    disposed = 0;
    bridge = _Bridge();
  });

  testWidgets(
    'opens straight to the camera: no fields, no Next, no extra tap',
    (t) async {
      await open(t);
      expect(find.text('Add authenticator'), findsOneWidget);
      expect(cameras, 1);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Next'), findsNothing);
      expect(find.text('Verify and add'), findsNothing);
      expect(find.text('Enter key manually'), findsOneWidget);
      await _shot('add_authenticator_camera');
    },
  );

  testWidgets(
    'a bad scan keeps scanning with a message; a valid scan advances by itself',
    (t) async {
      await open(t);
      scan('https://example.test/not-a-key');
      await t.pump();
      expect(
        find.text('That QR code is not an authenticator setup code.'),
        findsOneWidget,
      );
      expect(find.text('Verify and add'), findsNothing);
      scan(_uri);
      await t.pumpAndSettle();
      expect(disposed, 1, reason: 'camera is released when the stage changes');
      expect(find.text('Verify and add'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('bob@example.test'), findsOneWidget);
      expect(find.text('JBSWY3DPEHPK3PXP'), findsNothing);
      scan(_uri);
      await t.pump();
      expect(bridge.adds, isEmpty);
      await _shot('add_authenticator_details');
      await t.tap(find.text('Verify and add'));
      await t.pumpAndSettle();
      expect(bridge.adds, [
        ['GitHub', 'bob@example.test', _uri],
      ]);
    },
  );

  testWidgets(
    'manual mode replaces the camera, Next waits for a valid key, toggle goes back',
    (t) async {
      await open(t);
      await t.tap(find.text('Enter key manually'));
      await t.pumpAndSettle();
      expect(disposed, 1);
      expect(find.text('Scan QR code'), findsOneWidget);
      bool nextEnabled() =>
          t
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
              .onPressed !=
          null;
      expect(nextEnabled(), isFalse);
      await t.enterText(find.byType(TextField), 'NOTAVALIDKEY');
      await t.pump();
      expect(nextEnabled(), isFalse);
      await t.enterText(find.byType(TextField), 'jbsw-y3dp ehpk 3pxp');
      await t.pump();
      expect(nextEnabled(), isTrue);
      await t.pump(const Duration(milliseconds: 500));
      await _shot('add_authenticator_manual');
      await t.tap(find.text('Scan QR code'));
      await t.pumpAndSettle();
      expect(cameras, 2);
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.text('Enter key manually'));
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await t.enterText(find.byType(TextField), 'JBSWY3DPEHPK3PXP');
      await t.pump();
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
      expect(find.text('Verify and add'), findsOneWidget);
      expect(
        t.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        isEmpty,
      );
      await t.enterText(find.byType(TextField).at(0), 'Mine');
      await t.tap(find.text('Verify and add'));
      await t.pumpAndSettle();
      expect(bridge.adds.single, ['Mine', '', 'JBSWY3DPEHPK3PXP']);
    },
  );

  testWidgets('camera permission or hardware problem points to manual entry', (
    t,
  ) async {
    await open(t);
    problem(QrCameraProblem.permissionDenied);
    await t.pump();
    expect(find.textContaining('Camera permission is off'), findsOneWidget);
    expect(find.text('Enter key manually'), findsOneWidget);
  });

  testWidgets(
    'cannot be dismissed while saving; the finished add returns its id',
    (t) async {
      final gate = bridge.gate = Completer<void>();
      String? result;
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async =>
                  result = await addTotpDialog(c, bridge, camera: fakeCamera),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      scan(_uri);
      await t.pumpAndSettle();
      await t.tap(find.text('Verify and add'));
      await t.pump();
      expect(bridge.adds, hasLength(1));
      // Outside tap (barrier) and back/route pop are both refused while busy.
      await t.tapAt(const Offset(5, 5));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      expect(result, isNull);
      gate.complete();
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(result, 'entry');
    },
  );

  testWidgets('after a failed save the dialog can be dismissed again', (
    t,
  ) async {
    await open(t);
    scan(_uri);
    await t.pumpAndSettle();
    bridge.failNext = true;
    await t.tap(find.text('Verify and add'));
    await t.pumpAndSettle();
    expect(bridge.adds, hasLength(1));
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'a camera problem is cleared when returning from manual entry so the camera retries',
    (t) async {
      await open(t);
      problem(QrCameraProblem.unavailable);
      await t.pump();
      expect(find.textContaining('camera is not available'), findsOneWidget);
      await t.tap(find.text('Enter key manually'));
      await t.pumpAndSettle();
      await t.tap(find.text('Scan QR code'));
      await t.pumpAndSettle();
      expect(find.textContaining('camera is not available'), findsNothing);
      expect(cameras, 2, reason: 'a new camera view was started');
      scan(_uri);
      await t.pumpAndSettle();
      expect(find.text('Verify and add'), findsOneWidget);
    },
  );

  test('parseSetupKey accepts display formats and refuses everything else', () {
    expect(parseSetupKey('JBSWY3DPEHPK3PXP')!.uri, 'JBSWY3DPEHPK3PXP');
    expect(parseSetupKey(' jbsw y3dp-ehpk 3pxp== ')!.uri, 'JBSWY3DPEHPK3PXP');
    expect(parseSetupKey(_uri)!.name, 'GitHub');
    expect(parseSetupKey(''), isNull);
    expect(parseSetupKey('JBSWY3DP'), isNull);
    expect(parseSetupKey('otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP'), isNull);
    expect(
      parseSetupKey('otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&evil=1'),
      isNull,
    );
  });
}

class _Fake extends StatefulWidget {
  const _Fake({required this.onInit, required this.onDispose});
  final VoidCallback onInit, onDispose;
  @override
  State<_Fake> createState() => _FakeState();
}

class _FakeState extends State<_Fake> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF222B33),
    child: Center(
      child: Text(
        'camera preview (test stand-in)',
        style: TextStyle(color: Colors.white70),
      ),
    ),
  );
}
