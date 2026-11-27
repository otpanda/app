import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

import 'browser_session_contract.dart';
import 'session_contract.dart';

/// Rename an owned entry, change its account name, or delete it. Opened from
/// the Entries tab. Returns true when something changed, so the caller reloads.
class EntryManageDialog extends StatefulWidget {
  final EntryManagementBridge bridge;
  final ManagedEntry entry;

  /// Called as soon as the server confirms the new label or account name, so
  /// the list can show it without waiting for a reload. Not called when the
  /// outcome is unknown.
  final void Function({String? service, String? account})? onConfirmed;
  const EntryManageDialog({
    super.key,
    required this.bridge,
    required this.entry,
    this.onConfirmed,
  });
  @override
  State<EntryManageDialog> createState() => _EntryManageDialogState();
}

class _EntryManageDialogState extends State<EntryManageDialog> {
  late final name = TextEditingController(text: widget.entry.service);
  late final account = TextEditingController(text: widget.entry.account);
  bool busy = false, changed = false;
  String error = '';

  @override
  void dispose() {
    name.dispose();
    account.dispose();
    super.dispose();
  }

  bool get dirty =>
      name.text.trim() != widget.entry.service ||
      account.text.trim() != widget.entry.account;
  bool get valid => name.text.trim().isNotEmpty;

  Future<void> run(Future<void> Function() action, {bool close = false}) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      changed = true;
      if (close && mounted) Navigator.pop(context, true);
    } catch (_) {
      // The server may or may not have applied it: reload before retrying.
      changed = true;
      if (mounted) {
        setState(
          () => error =
              'Could not confirm the change. Check the list, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() => run(() async {
    final label = name.text.trim();
    if (label != widget.entry.service) {
      await widget.bridge.renameEntry(widget.entry.id, label);
      widget.onConfirmed?.call(service: label);
    }
    final acc = account.text.trim();
    if (acc != widget.entry.account) {
      await widget.bridge.updateAccount(
        widget.entry.id,
        acc.isEmpty ? null : acc,
      );
      widget.onConfirmed?.call(account: acc);
    }
  }, close: true);

  Future<void> remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        key: const Key('entry-delete-confirm'),
        title: const Text('Delete this entry?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Text(
            '${widget.entry.service} and its codes will be removed from your account. This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const Key('entry-delete-yes'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final Object b = widget.bridge;
    if (b is! EntryDeleteBridge) return;
    await run(() => b.deleteEntry(widget.entry.id), close: true);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 400),
    key: const Key('entry-manage'),
    title: const Text('Edit entry'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.entry.issuer != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text('Issuer: ${widget.entry.issuer}'),
              ),
            TextField(
              key: const Key('entry-name'),
              controller: name,
              enabled: !busy,
              maxLength: 120,
              buildCounter: (
                _, {
                required currentLength,
                required isFocused,
                maxLength,
              }) => null,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            TextField(
              key: const Key('entry-account'),
              controller: account,
              enabled: !busy,
              maxLength: 120,
              buildCounter: (
                _, {
                required currentLength,
                required isFocused,
                maxLength,
              }) => null,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Account (optional)',
                helperText: 'Username or email',
              ),
            ),
            // Always reserve the line so the dialog does not jump.
            SizedBox(
              height: 40,
              child: error.isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        error,
                        key: const Key('entry-error'),
                        style: TextStyle(color: context.pal.danger),
                      ),
                    ),
            ),
            if (widget.bridge is EntryDeleteBridge)
              OutlinedButton.icon(
                key: const Key('entry-delete'),
                onPressed: busy ? null : remove,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete entry'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.pal.danger,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, changed),
        child: const Text('Cancel'),
      ),
      FilledButton.icon(
        key: const Key('entry-save'),
        onPressed: busy || !dirty || !valid ? null : save,
        icon: const Icon(Icons.check),
        label: const Text('Save'),
      ),
    ],
  );
}
