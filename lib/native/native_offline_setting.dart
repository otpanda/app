import 'package:material_ui/material_ui.dart';

import 'native_offline_enrollment.dart';

/// Enrollment is an explicit user gesture because it may open the OS passkey
/// prompt. No passkey ceremony runs from build, app startup or a background tick.
class NativeOfflineSetting extends StatelessWidget {
  const NativeOfflineSetting({super.key, required this.enrollment});
  final NativeOfflineEnrollment enrollment;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: enrollment,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Offline authenticator codes'),
          const SizedBox(height: 8),
          const Text(
            'Your own saved authenticator codes can work without a connection. Shared codes expire normally. This device keeps an encrypted local copy protected by the operating system.',
          ),
          if (enrollment.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(enrollment.message!),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed:
                enrollment.owner == null ||
                    enrollment.busy ||
                    !enrollment.enabled
                ? null
                : enrollment.setUp,
            child: Text(
              enrollment.busy
                  ? 'Setting up...'
                  : enrollment.confirmed
                  ? 'Check offline setup'
                  : 'Set up on this device',
            ),
          ),
        ],
      ),
    ),
  );
}
