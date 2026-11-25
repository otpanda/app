import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'entry_domains.dart';
import 'session_contract.dart';

/// The viewer's own extra websites for one entry (owned or shared with them).
/// Reads the current list first and offers editing only once it is loaded, so
/// a failed read can never be followed by a replace that wipes the list.
/// Pops true when a replace may have been applied, so the caller can reload.
class EntryDomainsDialog extends StatefulWidget {
  final EntryDomainsBridge bridge;
  final ManagedEntry entry;
  const EntryDomainsDialog({
    super.key,
    required this.bridge,
    required this.entry,
  });
  @override
  State<EntryDomainsDialog> createState() => _EntryDomainsDialogState();
}

class _EntryDomainsDialogState extends State<EntryDomainsDialog> {
  final input = TextEditingController();
  List<String>? saved; // null until read
  List<String> current = [];
  bool loading = true, busy = false, changed = false;
  String error = '', loadError = '';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      loadError = '';
    });
    try {
      final all = await widget.bridge.readEntryDomains();
      if (!mounted) return;
      setState(() {
        saved = List.of(all[widget.entry.id] ?? const <String>[]);
        current = List.of(saved!);
      });
    } catch (_) {
      if (mounted) setState(() => loadError = 'Could not load websites.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  bool get dirty =>
      saved != null &&
      (saved!.length != current.length ||
          [for (var i = 0; i < current.length; i++) saved![i] != current[i]]
              .any((x) => x));

  void add() {
    final h = normalizeEntryDomain(input.text);
    if (h == null) {
      setState(() => error = 'Enter one exact website such as example.com.');
      return;
    }
    if (current.contains(h)) {
      setState(() => error = '$h is already listed.');
      return;
    }
    if (current.length >= entryDomainsMax) {
      setState(() => error = 'You can add up to $entryDomainsMax websites.');
      return;
    }
    setState(() {
      current = [...current, h];
      input.clear();
      error = '';
    });
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.bridge.replaceEntryDomains(widget.entry.id, current);
      changed = true;
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      // The server may or may not have applied it. Do not guess: ask to reload.
      changed = true;
      if (mounted) {
        setState(
          () => error =
              'Could not confirm the change. Reload the list, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('entry-domains'),
    title: Text('Websites for ${widget.entry.service}'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: SingleChildScrollView(
        child: loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : saved == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(loadError, key: const Key('domains-load-error')),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('domains-retry'),
                    onPressed: load,
                    child: const Text('Try again'),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Codes for this entry fill only on exactly these websites. '
                    'A subdomain or parent domain is not included unless you '
                    'add it. Only you see this list.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  if (current.isEmpty)
                    const Text('No websites yet.', key: Key('domains-empty')),
                  for (final d in current)
                    Row(
                      children: [
                        Expanded(child: Text(d)),
                        IconButton(
                          key: Key('domain-remove-$d'),
                          tooltip: 'Remove $d',
                          onPressed: busy
                              ? null
                              : () => setState(
                                  () => current = [
                                    for (final x in current)
                                      if (x != d) x,
                                  ],
                                ),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('domain-input'),
                          controller: input,
                          enabled: !busy,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          onSubmitted: (_) => add(),
                          decoration: const InputDecoration(
                            labelText: 'Website',
                            hintText: 'example.com',
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('domain-add'),
                        tooltip: 'Add website',
                        onPressed: busy ? null : add,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: 40,
                    child: error.isEmpty
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              error,
                              key: const Key('domains-error'),
                              style: const TextStyle(color: Color(0xffb3261e)),
                            ),
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
        key: const Key('domains-save'),
        onPressed: busy || !dirty ? null : save,
        icon: const Icon(Icons.check),
        label: const Text('Save'),
      ),
    ],
  );
}
