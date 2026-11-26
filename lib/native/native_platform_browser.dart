import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart' show otpandaTheme;

/// Native authentication adapters are Android-only. Other installed targets
/// use the supported browser app, rather than calling Android channels.
class NativePlatformBrowserApp extends StatelessWidget {
  const NativePlatformBrowserApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: otpandaTheme(),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/brand-v7/otty-circle-192.png',
                width: 72,
                height: 72,
              ),
              const SizedBox(height: 24),
              const Text(
                'OTPanda',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Use the browser app on this platform to sign in and view your codes.',
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://otpanda.github.io/app/'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('Open browser app'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
