import 'dart:async';
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

// Synthetic transport and platform replies. This proves actual root/session,
// button and channel routing, not Android provider or biometric behavior.
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
  Future<String?> readDeviceId() async => 'DEV';
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

void main() {
  setUpAll(() async {
    final loader = FontLoader('Figtree')
      ..addFont(
        File('assets/fonts/Figtree-400.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)),
      );
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          '/downloads/otpanda/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then((b) => ByteData.sublistView(b)),
      );
    await icons.load();
  });
  for (final disable in [false, true]) {
    for (final cancelSession in [false, true]) {
      testWidgets(
        'actual root recovery button, fresh session bearer, disable=$disable cancel=$cancelSession',
        (t) async {
          t.view.physicalSize = const Size(390, 844);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.resetPhysicalSize);
          addTearDown(t.view.resetDevicePixelRatio);
          var saved = true, grants = 0, renews = 0, cancels = 0;
          final pending = Completer<String>();
          var denyRenew = false;
          var now = DateTime.fromMillisecondsSinceEpoch(1000000);
          final calls = <Map<dynamic, dynamic>>[];
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          for (final name in [
            'app.otpanda/google',
            'app.otpanda/passkey',
            'app.otpanda/native',
          ]) {
            messenger.setMockMethodCallHandler(
              MethodChannel(name),
              (c) async => false,
            );
          }
          messenger.setMockMethodCallHandler(
            const MethodChannel('app.otpanda/app-lock'),
            (c) async {
              if (c.method == 'enabled') return saved;
              if (c.method == 'verify') return false;
              throw StateError('unexpected app-lock call ${c.method}');
            },
          );
          messenger.setMockMethodCallHandler(
            const MethodChannel('app.otpanda/lock-recovery'),
            (c) async {
              if (c.method == 'cancel') {
                cancels++;
                return null;
              }
              if (c.method == 'consumeUnlock') return grants++ == 0;
              if (c.method == 'start') {
                calls.add(c.arguments as Map<dynamic, dynamic>);
                if (cancelSession) return pending.future;
                if (disable) saved = false;
                return disable ? 'DISABLED' : 'UNLOCK_GRANTED';
              }
              throw StateError('unexpected recovery call ${c.method}');
            },
          );
          final controller = NativeSessionController(
            NativeAuth(
              post: (p, b) async {
                if (p == '/auth/native/challenge') {
                  return (
                    status: 200,
                    body: <String, dynamic>{
                      'device_id': 'DEV',
                      'nonce': 'n',
                      'expires_at': 5,
                    },
                  );
                }
                if (p == '/auth/native/renew') {
                  if (denyRenew) {
                    return (status: 401, body: <String, dynamic>{});
                  }
                  renews++;
                  return (
                    status: 200,
                    body: <String, dynamic>{
                      'access': 'synthetic-access-$renews',
                      'access_expires_at': now.millisecondsSinceEpoch + 300000,
                    },
                  );
                }
                throw StateError('unexpected network route $p');
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
          final pixels = GlobalKey();
          await t.pumpWidget(
            RepaintBoundary(
              key: pixels,
              child: buildAndroidNativeRootForTest(
                session: controller,
                request: (method, path, {body, query, required bearer}) async =>
                    const SessionResponse(503, '{}'),
              ),
            ),
          );
          for (var i = 0; i < 15; i++) {
            await t.pump(const Duration(milliseconds: 100));
          }
          expect(find.text('OTPanda is locked'), findsOneWidget);
          expect(renews, 1);
          expect(calls, isEmpty); // no auto-recovery or lock enable
          if (!disable && !cancelSession) {
            await t.runAsync(() async {
              final image =
                  await (pixels.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File('/downloads/root-lock-before.png')
                  .writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
          now = now.add(const Duration(seconds: 250));
          await t.tap(
            find.text(
              disable
                  ? 'Turn off app lock with a passkey'
                  : 'Unlock once with a passkey',
            ),
          );
          for (var i = 0; i < 15; i++) {
            await t.pump(const Duration(milliseconds: 100));
          }
          if (cancelSession) {
            denyRenew = true;
            await controller.forceRenew();
            await t.pump();
            expect(controller.phase, NativeSessionPhase.signInRequired);
            expect(cancels, greaterThan(0));
            pending.complete('UNLOCK_GRANTED');
            await t.pump();
            await t.pump(const Duration(milliseconds: 100));
            expect(find.text('OTPanda is locked'), findsOneWidget);
            expect(saved, true);
            expect(grants, 0); // late grant is not consumed
          }
          expect(renews, 2); // actual controller.accessToken refreshes first
          expect(calls, hasLength(1));
          expect(calls.single, {
            'intent': disable ? 'local-lock-disable' : 'local-unlock-once',
            'bearer': 'synthetic-access-2',
          });
          if (!cancelSession) {
            expect(find.text('OTPanda is locked'), findsNothing);
            expect(saved, !disable);
            expect(grants, disable ? 0 : 1);
          }
          await t.pumpWidget(const SizedBox.shrink());
          for (var i = 0; i < 15; i++) {
            await t.pump(const Duration(milliseconds: 100));
          }
          expect(cancels, greaterThan(0));
          controller.dispose();
          messenger.setMockMethodCallHandler(
            const MethodChannel('app.otpanda/app-lock'),
            null,
          );
          messenger.setMockMethodCallHandler(
            const MethodChannel('app.otpanda/lock-recovery'),
            null,
          );
        },
      );
    }
  }
}
