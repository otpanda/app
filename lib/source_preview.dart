import 'package:material_ui/material_ui.dart';

/// Fictional source preview, never an enrollment or provider connection.
class SourcePreview extends StatelessWidget {
  final bool revoked;
  final VoidCallback onRevoke;
  const SourcePreview({
    super.key,
    required this.revoked,
    required this.onRevoke,
  });
  Future<void> revoke(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        title: Row(
          children: [
            const Expanded(child: Text('Revoke this source?')),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context, false),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        scrollable: true,
        content: const Text(
          'In a connected account this rejects new uploads and stops serving existing codes from this source. This demo changes only a fictional source and resets when restarted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke source'),
          ),
        ],
      ),
    );
    if (yes == true && context.mounted) {
      onRevoke();
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Phones and mailboxes that send codes to your account. SMS collection is always opt-in.',
      ),
      const SizedBox(height: 14),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pixel phone',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(revoked ? 'SMS · Revoked in this demo' : 'SMS · Active'),
              if (!revoked)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => revoke(context),
                    child: const Text('Revoke source'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}
