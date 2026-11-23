import 'package:material_ui/material_ui.dart';

/// UI parity only. No bearer credential is generated or stored in this demo.
class AccessPreview extends StatelessWidget {
  final bool tokenRevoked;
  final VoidCallback onRevoke;
  const AccessPreview({
    super.key,
    required this.tokenRevoked,
    required this.onRevoke,
  });
  Future<void> revoke(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Expanded(child: Text('Revoke app access?')),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context, false),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        scrollable: true,
        content: const Text(
          'In a connected account this stops this app from reading codes for the selected entry. It does not delete the entry or change access for people. This demo only changes fictional app access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke app access'),
          ),
        ],
      ),
    );
    if (yes == true && context.mounted) onRevoke();
  }

  Widget panel(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'People and apps have separate permissions. Nothing here grants real access.',
      ),
      const SizedBox(height: 14),
      panel([
        const Text('People', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 8),
        const Text(
          'Fictional teammate',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const Text('Northstar · alex@example.test only'),
        const SizedBox(height: 8),
        const Text('Read-only codes · Automation not allowed'),
        const SizedBox(height: 8),
        const Text(
          'Sharing invitations and changes are not connected in this preview.',
          style: TextStyle(fontSize: 11),
        ),
      ]),
      const SizedBox(height: 12),
      panel([
        const Text('Apps & automation', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 8),
        const Text(
          'Fictional laptop assistant',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const Text('Northstar · alex@example.test only'),
        const SizedBox(height: 8),
        Text(
          tokenRevoked
              ? 'Revoked in this demo'
              : 'Read codes for this entry only',
        ),
        if (!tokenRevoked)
          TextButton(
            onPressed: () => revoke(context),
            child: const Text('Revoke app access'),
          ),
        const SizedBox(height: 8),
        const Text(
          'No real token exists. Token creation, expiry and one-time credential display are not connected.',
          style: TextStyle(fontSize: 11),
        ),
      ]),
    ],
  );
}
