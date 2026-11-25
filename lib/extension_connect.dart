import 'package:material_ui/material_ui.dart';

/// Confirmation side of the browser-extension sign-in. The web bridge keeps a
/// strictly parsed intent from the extension's identity window. Nothing is sent
/// until the signed-in user presses Connect, and only that press calls begin.
/// A bridge that cannot do this does not implement it and no dialog appears.
abstract interface class ExtensionConnectBridge {
  /// Empty, or the redirect key (chrome, firefox) of a pending intent.
  String get extensionIntent;

  /// Empty when the browser is leaving for the extension, otherwise a reason
  /// code: expired, signin, retry, restart or unavailable.
  Future<String> connectExtension();

  /// Drops the pending intent without calling anything.
  void cancelExtension();
}

String extensionConnectMessage(String reason) => switch (reason) {
  'expired' || 'restart' =>
    'This request expired. Open the extension and choose Sign in again.',
  'signin' => 'Sign in again here, then open the extension and retry.',
  'retry' => 'Too many tries. Wait a minute and press Connect again.',
  _ => 'Could not connect the extension. Try again.',
};

/// Shows the confirmation once for a pending intent. Returns when closed.
Future<void> showExtensionConnectDialog(
  BuildContext context,
  ExtensionConnectBridge bridge,
) async {
  if (bridge.extensionIntent.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExtensionConnectDialog(bridge: bridge),
  );
}

class _ExtensionConnectDialog extends StatefulWidget {
  final ExtensionConnectBridge bridge;
  const _ExtensionConnectDialog({required this.bridge});
  @override
  State<_ExtensionConnectDialog> createState() =>
      _ExtensionConnectDialogState();
}

class _ExtensionConnectDialogState extends State<_ExtensionConnectDialog> {
  bool busy = false;
  String message = '';

  Future<void> connect() async {
    setState(() {
      busy = true;
      message = '';
    });
    String reason;
    try {
      reason = await widget.bridge.connectExtension();
    } catch (_) {
      reason = 'unavailable';
    }
    if (!mounted) return;
    // Empty means the page is already leaving for the extension.
    if (reason.isEmpty) return;
    setState(() {
      busy = false;
      message = extensionConnectMessage(reason);
    });
  }

  void cancel() {
    widget.bridge.cancelExtension();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect browser extension?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'The OTPanda extension in your browser asked to sign in to this account. It gets its own sign-in that works only for the extension. Continue only if you just opened it from the extension.',
        ),
        if (message.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(message, key: const Key('extension-connect-message')),
        ],
      ],
    ),
    actions: [
      TextButton(
        key: const Key('extension-connect-cancel'),
        onPressed: busy ? null : cancel,
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('extension-connect-confirm'),
        onPressed: busy ? null : connect,
        child: const Text('Connect'),
      ),
    ],
  );
}
