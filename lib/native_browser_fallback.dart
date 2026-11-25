import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'branding.dart';
import 'main.dart' show green, ink, line, muted, otpandaTheme;

/// The live web app. Accounts, passkeys and codes stay there until the native
/// client has its own secure sign-in. Nothing is copied from the browser.
final Uri liveWebAppUrl = Uri.parse('https://otpanda.github.io/app/');

/// Set by the release build, for example 0.1.0-alpha.1. Empty in local builds.
const String appVersion = String.fromEnvironment('APP_VERSION');

typedef UrlLauncher = Future<bool> Function(Uri url);

/// Opens the URL in the system browser, never an embedded web view.
Future<bool> launchInSystemBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

/// Shown by non-web builds until native sign-in exists. It offers one real
/// action, opening the web app, and no sign-in or authenticator controls.
class NativeBrowserFallbackApp extends StatelessWidget {
  final UrlLauncher launcher;
  const NativeBrowserFallbackApp({
    super.key,
    this.launcher = launchInSystemBrowser,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OTPanda',
    debugShowCheckedModeBanner: false,
    theme: otpandaTheme(),
    home: NativeBrowserFallbackPage(launcher: launcher),
  );
}

class NativeBrowserFallbackPage extends StatefulWidget {
  final UrlLauncher launcher;
  const NativeBrowserFallbackPage({
    super.key,
    this.launcher = launchInSystemBrowser,
  });
  @override
  State<NativeBrowserFallbackPage> createState() => _FallbackState();
}

class _FallbackState extends State<NativeBrowserFallbackPage> {
  bool failed = false;

  Future<void> open() async {
    var opened = false;
    try {
      opened = await widget.launcher(liveWebAppUrl);
    } catch (_) {
      opened = false;
    }
    if (mounted) setState(() => failed = !opened);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Image.memory(
                  ottyImage,
                  width: 72,
                  height: 72,
                  semanticLabel: 'OTPanda mascot',
                ),
                const SizedBox(height: 20),
                const Text(
                  'Sign-in on this device is not ready yet',
                  style: TextStyle(
                    color: ink,
                    fontFamily: 'BricolageGrotesque',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'This development build cannot sign in, use passkeys or show '
                  'verification codes yet. Your account works in the browser, '
                  'so open OTPanda there for now.',
                  style: TextStyle(color: muted, fontSize: 15, height: 1.4),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: green),
                    onPressed: open,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open OTPanda in browser'),
                  ),
                ),
                if (failed) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: line),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      'No browser could be opened. Visit $liveWebAppUrl',
                      style: const TextStyle(color: ink, fontSize: 13),
                    ),
                  ),
                ],
                if (appVersion.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Version $appVersion',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
