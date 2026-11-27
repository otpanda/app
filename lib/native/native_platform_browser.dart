import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../theme_controller.dart';
import '../branding.dart';

/// Native authentication adapters are Android-only. Other installed targets
/// use the supported browser app, rather than calling Android channels.
class NativePlatformBrowserApp extends StatelessWidget {
  const NativePlatformBrowserApp({super.key, this.themeController});
  final ThemeController? themeController;
  @override
  Widget build(BuildContext context) => ThemeScope(
    controller: themeController ?? appThemeController,
    builder: (context, light, dark, mode) => MaterialApp(
      theme: light,
      darkTheme: dark,
      themeMode: mode,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.memory(ottyImage, width: 72, height: 72),
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
    ),
  );
}
