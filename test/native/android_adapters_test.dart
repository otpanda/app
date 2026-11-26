import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/android_adapters.dart';
import 'package:otpanda_client/native/native_auth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late String? pendingLink;

  setUp(() {
    calls = [];
    pendingLink = null;
    messenger.setMockMethodCallHandler(nativeChannel, (c) async {
      calls.add(c);
      switch (c.method) {
        case 'takeInitialLink':
          final l = pendingLink;
          pendingLink = null;
          return l;
        case 'ensureKey':
        case 'beginNewKey':
          return Uint8List.fromList([4, ...List.filled(64, 7)]);
        case 'hasPendingKey':
          return true;
        case 'sign':
          return Uint8List.fromList([1, 2, 3]);
      }
      return null;
    });
  });

  test(
    'keystore adapter maps to the native contract with no alias argument',
    () async {
      final k = AndroidKeystoreAdapter();
      expect((await k.ensureKey()).length, 65);
      expect((await k.beginNewKey()).first, 4);
      await k.commitNewKey();
      await k.discardNewKey();
      expect(await k.signDer(Uint8List.fromList([9])), [1, 2, 3]);
      expect(await k.hasPendingKey(), isTrue);
      await k.deleteKey();
      expect(calls.map((c) => c.method), [
        'ensureKey',
        'beginNewKey',
        'commitNewKey',
        'discardNewKey',
        'sign',
        'hasPendingKey',
        'deleteKey',
      ]);
      expect(calls.last.arguments, isNull);
    },
  );

  testWidgets(
    'custom tab: closing the tab (resume, no link) cancels after grace',
    (t) async {
      final h = CustomTabHandoff(
        grace: const Duration(milliseconds: 50),
        launch: (u) async => true,
      );
      Uri? out = Uri.parse('x:');
      final f = h
          .run(Uri.parse('https://otpanda.github.io/app/'))
          .then((v) => out = v);
      await t.pump();
      h.didChangeAppLifecycleState(AppLifecycleState.paused);
      h.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await t.pump(const Duration(milliseconds: 10));
      expect(out.toString(), 'x:');
      await t.pump(const Duration(milliseconds: 100));
      await f;
      expect(out, isNull);
    },
  );

  testWidgets('custom tab: link waiting natively is pulled on resume', (
    t,
  ) async {
    final h = CustomTabHandoff(
      grace: const Duration(seconds: 5),
      launch: (u) async => true,
    );
    Uri? out;
    final f = h
        .run(Uri.parse('https://otpanda.github.io/app/'))
        .then((v) => out = v);
    await t.pump();
    pendingLink = 'https://otpanda-api.abrahammurciano.workers.dev/app-return#code=c&state=s';
    h.didChangeAppLifecycleState(AppLifecycleState.paused);
    h.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await t.pump(const Duration(milliseconds: 10));
    await f;
    expect(out!.fragment, 'code=c&state=s');
  });

  testWidgets(
    'custom tab: pushed appLink completes; stale link is dropped at start',
    (t) async {
      pendingLink = 'https://otpanda-api.abrahammurciano.workers.dev/app-return#code=OLD&state=OLD';
      final h = CustomTabHandoff(launch: (u) async => true);
      Uri? out;
      final f = h
          .run(Uri.parse('https://otpanda.github.io/app/'))
          .then((v) => out = v);
      await t.pump();
      expect(pendingLink, isNull); // stale link consumed
      await messenger.handlePlatformMessage(
        'app.otpanda/native',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall(
            'appLink',
            'https://otpanda-api.abrahammurciano.workers.dev/app-return#code=n&state=n',
          ),
        ),
        (_) {},
      );
      await f;
      expect(out!.fragment, 'code=n&state=n');
    },
  );

  testWidgets('custom tab: launch failure returns null immediately', (t) async {
    final h = CustomTabHandoff(launch: (u) async => false);
    expect(await h.run(Uri.parse('https://otpanda.github.io/app/')), isNull);
  });

  test('google source hidden without a client id or native side', () async {
    final none = AndroidGoogleSource(serverClientId: '');
    await none.probe();
    expect(none.available, isFalse);
    final missing = AndroidGoogleSource(
      serverClientId: 'id.apps.googleusercontent.com',
    );
    await missing.probe(); // no handler registered: F-Droid shape
    expect(missing.available, isFalse);
    messenger.setMockMethodCallHandler(googleChannel, (c) async {
      if (c.method == 'available') return true;
      if (c.method == 'idToken') {
        expect(c.arguments, {
          'nonce': 'N',
          'serverClientId': 'id.apps.googleusercontent.com',
        });
        return 'tok';
      }
      return null;
    });
    final g = AndroidGoogleSource(
      serverClientId: 'id.apps.googleusercontent.com',
    );
    await g.probe();
    expect(g.available, isTrue);
    expect(await g.idToken(nonce: 'N'), 'tok');
  });
  test('keystore failures are normalized to NativeAuthException', () async {
    messenger.setMockMethodCallHandler(
      nativeChannel,
      (c) async => throw PlatformException(code: 'keystore'),
    );
    final k = AndroidKeystoreAdapter();
    for (final f in <Future<Object?> Function()>[
      k.ensureKey,
      k.beginNewKey,
      k.commitNewKey,
      k.discardNewKey,
      k.hasPendingKey,
      k.deleteKey,
      () => k.signDer(Uint8List(1)),
    ]) {
      await expectLater(f(), throwsA(isA<NativeAuthException>()));
    }
    messenger.setMockMethodCallHandler(nativeChannel, null);
    await expectLater(k.ensureKey(), throwsA(isA<NativeAuthException>()));
  });
}
