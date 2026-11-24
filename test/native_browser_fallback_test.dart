import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/native_browser_fallback.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart' show LinkDelegate;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _FakeLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> urls = [];
  final List<PreferredLaunchMode> modes = [];
  @override
  LinkDelegate? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    modes.add(options.mode);
    return true;
  }
}

Future<void> pumpPage(
  WidgetTester t, {
  UrlLauncher launcher = launchInSystemBrowser,
  Size size = const Size(390, 780),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(NativeBrowserFallbackApp(launcher: launcher));
}

void main() {
  testWidgets('says sign-in is not ready and offers only the browser', (
    t,
  ) async {
    await pumpPage(t);
    expect(
      find.text('Sign-in on this device is not ready yet'),
      findsOneWidget,
    );
    expect(find.text('Open OTPanda in browser'), findsOneWidget);
    // No misleading native account controls.
    for (final label in [
      'Sign in',
      'Continue with Google',
      'Add authenticator',
      'Create account',
      'Use a passkey',
    ]) {
      expect(find.textContaining(label), findsNothing);
    }
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('opens the live web app through the injected launcher', (
    t,
  ) async {
    final calls = <Uri>[];
    await pumpPage(
      t,
      launcher: (url) async {
        calls.add(url);
        return true;
      },
    );
    await t.tap(find.text('Open OTPanda in browser'));
    await t.pump();
    expect(calls, [Uri.parse('https://otpanda.github.io/app/')]);
    expect(find.textContaining('No browser could be opened'), findsNothing);
  });

  testWidgets('launches an external application via the platform', (t) async {
    final fake = _FakeLauncher();
    final previous = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = fake;
    addTearDown(() => UrlLauncherPlatform.instance = previous);
    await pumpPage(t);
    await t.tap(find.text('Open OTPanda in browser'));
    await t.pump();
    expect(fake.urls, ['https://otpanda.github.io/app/']);
    // The system browser, not an in-app web view.
    expect(fake.modes, [PreferredLaunchMode.externalApplication]);
  });

  testWidgets('shows the address when no browser can be opened', (t) async {
    await pumpPage(t, launcher: (_) async => false);
    await t.tap(find.text('Open OTPanda in browser'));
    await t.pump();
    expect(
      find.textContaining('https://otpanda.github.io/app/'),
      findsOneWidget,
    );
    expect(find.textContaining('No browser could be opened'), findsOneWidget);
  });

  testWidgets('a launcher that throws is handled', (t) async {
    await pumpPage(t, launcher: (_) async => throw Exception('no handler'));
    await t.tap(find.text('Open OTPanda in browser'));
    await t.pump();
    expect(find.textContaining('No browser could be opened'), findsOneWidget);
  });

  testWidgets('fits a narrow phone and a wide desktop without overflow', (
    t,
  ) async {
    await pumpPage(t, size: const Size(320, 560));
    expect(t.takeException(), isNull);
    await pumpPage(t, size: const Size(1280, 800));
    expect(t.takeException(), isNull);
  });
}
