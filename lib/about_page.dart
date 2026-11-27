import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

import 'package:url_launcher/url_launcher.dart';

const String appVersion = String.fromEnvironment('APP_VERSION');

final Uri githubUrl = Uri.parse('https://github.com/otpanda/app');
final Uri iconLicenseUrl = Uri.parse('https://fontawesome.com/license/free');
final Uri landingUrl = Uri.parse('https://otpanda.github.io/home/');

/// Settings > About: version, project links and the open-source licenses.
/// Everything is static, so the page never waits on data.
class AboutPage extends StatelessWidget {
  final Future<bool> Function(Uri url) open;
  const AboutPage({this.open = _openExternal, super.key});

  static Future<bool> _openExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  Widget _row(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    IconData trailing = Icons.chevron_right,
  }) => ListTile(
    key: key,
    leading: Icon(icon, color: context.pal.accent),
    title: Text(
      title,
      style: TextStyle(fontWeight: FontWeight.w700, color: context.pal.ink),
    ),
    subtitle: Text(subtitle, style: TextStyle(color: context.pal.muted)),
    trailing: Icon(trailing, color: context.pal.muted),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final version = appVersion.isEmpty ? 'Development build' : appVersion;
    return Card(
      elevation: 0,
      color: context.pal.card,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.pal.line),
      ),
      child: Column(
        children: [
          ListTile(
            key: const Key('about-version'),
            leading: Icon(Icons.info_outline, color: context.pal.accent),
            title: Text(
              'Version',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: context.pal.ink,
              ),
            ),
            subtitle: Text(version, style: TextStyle(color: context.pal.muted)),
          ),
          Divider(height: 1, color: context.pal.line),
          _row(
            context,
            key: const Key('about-website'),
            icon: Icons.language,
            title: 'Website',
            subtitle: 'otpanda.github.io/home',
            trailing: Icons.open_in_new,
            onTap: () => open(landingUrl),
          ),
          Divider(height: 1, color: context.pal.line),
          _row(
            context,
            key: const Key('about-github'),
            icon: Icons.code,
            title: 'Source code',
            subtitle: 'github.com/otpanda/app',
            trailing: Icons.open_in_new,
            onTap: () => open(githubUrl),
          ),
          Divider(height: 1, color: context.pal.line),
          _row(
            context,
            key: const Key('about-icon-credit'),
            icon: Icons.image_outlined,
            title: 'Device logos',
            subtitle: 'Font Awesome Free, CC BY 4.0',
            trailing: Icons.open_in_new,
            onTap: () => open(iconLicenseUrl),
          ),
          Divider(height: 1, color: context.pal.line),
          _row(
            context,
            key: const Key('settings-licenses'),
            icon: Icons.description_outlined,
            title: 'Open-source licenses',
            subtitle: 'Fonts, icons and libraries OTPanda uses',
            onTap: () =>
                showLicensePage(context: context, applicationName: 'OTPanda'),
          ),
        ],
      ),
    );
  }
}
