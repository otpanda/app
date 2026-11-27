import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'rule_action_dialog.dart';

/// Owner-only persistent rules, fetched afresh for this Details route.
class EntryRuleSources extends StatefulWidget {
  const EntryRuleSources({
    super.key,
    required this.bridge,
    required this.entryId,
  });
  final RuleBridge bridge;
  final String entryId;
  @override
  State<EntryRuleSources> createState() => _EntryRuleSourcesState();
}

class _EntryRuleSourcesState extends State<EntryRuleSources> {
  List<Map<String, dynamic>>? rules;
  String error = '';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final j = jsonDecode(await widget.bridge.readRules());
      if (j is! Map || j['rules'] is! List) throw const FormatException();
      final rows = <Map<String, dynamic>>[];
      for (final r in j['rules']) {
        if (r is! Map<String, dynamic> ||
            r['ruleId'] is! String ||
            r['entryId'] is! String ||
            r['sourceId'] is! String ||
            r['sender'] is! String ||
            !['active', 'paused', 'needs_reassign'].contains(r['status']) ||
            !['template', 'phrase', 'sender'].contains(r['basis'])) {
          throw const FormatException();
        }
        if (r['entryId'] == widget.entryId) rows.add(r);
      }
      if (mounted) {
        setState(() {
          rules = rows;
          error = j['next'] != null
              ? 'More rules exist. Reloading a complete list is required before bulk changes.'
              : '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not load matching rules.');
    }
  }

  Future<void> action(Map<String, dynamic> r, String op) async {
    if (busy) return;
    if (op == 'delete') {
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Delete matching rule?'),
          content: Text(
            'Stop future matching from ${r['sender']}. Existing codes are not deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Delete rule'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      setState(() => busy = true);
      try {
        await widget.bridge.deleteRule(r['ruleId']);
        await load();
      } catch (_) {
        if (mounted) {
          setState(
            () => error =
                'Deletion outcome unconfirmed. Reload before trying again.',
          );
        }
      } finally {
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    String? phrase;
    if (op == 'edit') {
      final input = TextEditingController(text: r['phrase'] ?? '');
      final value = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Change matching basis'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Set a phrase, or leave blank to restore the saved template. A phrase can match other message templates.',
              ),
              TextField(
                controller: input,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Matching phrase'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, input.text.trim()),
              child: const Text('Review change'),
            ),
          ],
        ),
      );
      input.dispose();
      if (value == null || !mounted) return;
      phrase = value.isEmpty ? null : value.toLowerCase();
    }
    if (!mounted) return;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RuleActionDialog(
        bridge: widget.bridge,
        target: {
          'operation': op,
          'entryId': widget.entryId,
          'ruleId': r['ruleId'],
          if (op == 'edit') 'phrase': phrase,
        },
      ),
    );
    await load();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (rules == null && error.isEmpty)
        const Text('Loading matching rules...'),
      if (rules?.isEmpty == true) const Text('No saved email or SMS rules.'),
      for (final r in rules ?? <Map<String, dynamic>>[])
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r['sourceLabel'] ?? r['kind']} · ${r['sender']}'),
              Text(
                '${r['status'] == 'paused'
                    ? 'Paused'
                    : r['status'] == 'needs_reassign'
                    ? 'Needs reassignment'
                    : 'Active'} · ${r['basis'] == 'phrase'
                    ? 'phrase "${r['phrase']}"'
                    : r['basis'] == 'template'
                    ? 'message template'
                    : 'legacy sender rule'}',
              ),
              Wrap(
                spacing: 6,
                children: [
                  if (r['status'] == 'paused')
                    TextButton(
                      onPressed: busy ? null : () => action(r, 'resume'),
                      child: const Text('Resume'),
                    ),
                  if (r['status'] == 'active')
                    TextButton(
                      onPressed: busy ? null : () => action(r, 'edit'),
                      child: const Text('Change match'),
                    ),
                  TextButton(
                    onPressed: busy ? null : () => action(r, 'delete'),
                    child: const Text('Delete rule'),
                  ),
                ],
              ),
            ],
          ),
        ),
      if (error.isNotEmpty) Text(error),
      if (error.isNotEmpty)
        TextButton(
          onPressed: busy ? null : load,
          child: const Text('Reload rules'),
        ),
    ],
  );
}
