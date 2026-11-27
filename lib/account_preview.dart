import 'browser_account_page.dart';

import 'package:material_ui/material_ui.dart';

/// An explorable security setup preview. Never collects credentials or claims
/// that a passkey, provider or recovery key has actually been enrolled.
class AccountSecurityPreview extends StatefulWidget {
  const AccountSecurityPreview({super.key});
  @override
  State<AccountSecurityPreview> createState() => _AccountSecurityPreviewState();
}

class _AccountSecurityPreviewState extends State<AccountSecurityPreview> {
  bool passkey = false, android = false;
  Future<void> change(bool isPasskey, bool enabled) async {
    final remaining = (isPasskey ? android : passkey);
    if (!enabled && !remaining) {
      final remove = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 400),
          title: const Text('No recovery option left'),
          content: const Text(
            'In a real account, losing every passkey and enrolled recovery device would mean losing access. Email alone cannot restore your vault. This changes the preview only.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep option'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove in preview'),
            ),
          ],
        ),
      );
      if (remove != true || !mounted) return;
    }
    setState(() {
      if (isPasskey) {
        passkey = enabled;
      } else {
        android = enabled;
      }
    });
  }

  Widget panel({
    required IconData icon,
    required String title,
    required String body,
    Widget? trailing,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 21),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(body),
          if (trailing != null) ...[const SizedBox(height: 10), trailing],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final options = (passkey ? 1 : 0) + (android ? 1 : 0);
    return Scaffold(
      appBar: AppBar(title: const Text('Account & security')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xfffff6df),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'SETUP PREVIEW · No account is signed in. These controls explain the planned recovery flow. They do not create or save credentials.',
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Your account, your way',
                style: TextStyle(
                  fontFamily: 'BricolageGrotesque',
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Use a passkey or a linked Google account for the same OTPanda account. Your verified account email is unique; connected mailboxes can be different.',
              ),
              const SizedBox(height: 18),
              panel(
                icon: Icons.key_outlined,
                title: 'Sign-in is not connected yet',
                body: 'Passkey and Google account setup will appear here after the real sign-in flow passes its security checks. Do not enter passwords, codes or recovery keys into this preview.',
              ),
              const SizedBox(height: 10),
              const Text(
                'Explore recovery readiness',
                style: TextStyle(
                  fontFamily: 'BricolageGrotesque',
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Try a sample setup below. Nothing is registered, and leaving this screen resets your choices.',
              ),
              const SizedBox(height: 14),
              panel(
                icon: options == 0
                    ? Icons.warning_amber_outlined
                    : Icons.shield_outlined,
                title: options == 0
                    ? 'At risk of losing access'
                    : options == 1
                    ? 'One example recovery option'
                    : 'Two example recovery options',
                body: options == 0
                    ? 'Register enough recovery options before relying on an account. If all independent credentials are lost, email alone is not a recovery shortcut.'
                    : options == 1
                    ? 'One option can be lost with a device or provider. Add another usable, independent option. Two devices using the same passkey provider are not automatically independent backups.'
                    : 'Check that both options are genuinely usable and independent. This preview cannot verify your devices, provider sync or hardware protection.',
              ),
              panel(
                icon: Icons.fingerprint,
                title: 'Passkey',
                body: 'Passkeys ask for device verification. Some sync through a provider; others stay on one device. Provider recovery and cross-device support vary.',
                trailing: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include a sample passkey'),
                  value: passkey,
                  onChanged: (value) => change(true, value),
                ),
              ),
              panel(
                icon: Icons.phone_android,
                title: 'Android recovery device',
                body: 'The planned Android 11+ app recovery key is separate from an ordinary session. It is protected by strong biometrics or the phone screen-lock PIN/password and does not expire just because the app is unused. Someone who knows the phone PIN could use it too. Reinstalling, clearing app data, resetting the phone or changing/removing its secure lock can lose the key.',
                trailing: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include a sample Android device'),
                  value: android,
                  onChanged: (value) => change(false, value),
                ),
              ),
              panel(
                icon: Icons.devices_outlined,
                title: 'Stay signed in',
                body: 'The planned session policy renews with use, so you should not need a new prompt on every visit. Browser cleanup, private browsing, revoked devices or suspicious credential reuse can still require sign-in. Device sessions and the durable Android recovery key are different.',
              ),
              const Text(
                'No SMS authentication, extra OTPanda password or manual backup-code burden is required by this design. Real account setup and device management are still being built.',
                style: TextStyle(color: Color(0xff657e70)),
              ),
              TextButton.icon(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(builder: (_) => const BrowserAccountPage()),
                ),
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('Real account connection'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
