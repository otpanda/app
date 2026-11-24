import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';

/// Call only from an explicitly enabled real-account surface, never fixtures.
class AssignmentDialog extends StatefulWidget {
  final AssignmentBridge bridge;
  final String sourceId, eventId, entryId;
  const AssignmentDialog({
    super.key,
    required this.bridge,
    required this.sourceId,
    required this.eventId,
    required this.entryId,
  });
  @override
  State<AssignmentDialog> createState() => _AssignmentDialogState();
}

class _AssignmentDialogState extends State<AssignmentDialog> {
  String state = 'loading';
  Map<String, dynamic>? summary;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    final current = widget.bridge.assignmentState;
    if (['unknown', 'pending', 'submitting'].contains(current)) {
      state = current;
      busy = false;
    } else {
      prepare();
    }
  }

  Future<void> prepare() async {
    try {
      final text = await widget.bridge.assignmentPrepare(
        jsonEncode({
          'sourceId': widget.sourceId,
          'eventId': widget.eventId,
          'entryId': widget.entryId,
        }),
      );
      if (text.length > 8192) throw const FormatException();
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> ||
          value['entryId'] != widget.entryId ||
          value['irreversible'] != true ||
          value['label'] is! String ||
          value['activeRecipients'] is! int ||
          value['automationRecipients'] is! int) {
        throw const FormatException();
      }
      if (!mounted) return;
      setState(() {
        summary = value;
        state = 'confirm';
        busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          state = 'unavailable';
          busy = false;
        });
      }
    }
  }

  Future<void> confirm() async {
    setState(() {
      busy = true;
      state = 'authenticating';
    });
    String result;
    try {
      result = await widget.bridge.assignmentConfirm();
    } catch (_) {
      result = 'unknown';
    }
    if (mounted) {
      setState(() {
        state = result;
        busy = false;
      });
    }
  }

  Future<void> check() async {
    setState(() => busy = true);
    String result;
    try {
      result = await widget.bridge.assignmentReconcile();
    } catch (_) {
      result = 'unknown';
    }
    if (mounted) {
      setState(() {
        state = result;
        busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final uncertain = ['unknown', 'pending', 'submitting'].contains(state);
    final s = summary;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Assign this code'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (s != null) ...[
                Text(
                  s['label'] as String,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if (s['accountName'] is String &&
                    (s['accountName'] as String).isNotEmpty)
                  Text(s['accountName'] as String),
                Text('Active recipients: ${s['activeRecipients']}'),
                Text(
                  'Recipients with automation access: ${s['automationRecipients']}',
                ),
                const SizedBox(height: 12),
                const Text(
                  'This releases this code to the selected entry. Recipients may read or save it immediately. Revoking access later cannot undo that. This does not assign future messages.',
                ),
              ],
              const SizedBox(height: 12),
              if (busy) const CircularProgressIndicator(),
              Text(switch (state) {
                'loading' => 'Checking the selected entry…',
                'confirm' => 'Check the account and recipients before confirming with your passkey.',
                'authenticating' =>
                  'Complete the passkey prompt. Do not submit again.',
                'assigned' => 'Assignment confirmed.',
                'not-assigned' => 'Server confirmed this assignment did not happen. Close to choose an entry and start a new confirmation.',
                'pending' => 'Assignment is still pending. No new assignment has been sent.',
                'unknown' => 'Could not confirm the outcome. It may have happened. Check status or sign in again and review the entry before trying a new assignment.',
                'cancelled' => 'Passkey cancelled. No assignment was sent.',
                'expired' => 'Confirmation expired. Close and start again.',
                'idle' => 'Session changed. Sign in and review the entry. A request already sent may still have completed.',
                _ =>
                  'Assignment is unavailable. No confirmation was requested.',
              }),
            ],
          ),
        ),
        actions: [
          if (state == 'confirm')
            FilledButton(
              onPressed: busy ? null : confirm,
              child: const Text('Confirm with passkey'),
            ),
          if (uncertain)
            OutlinedButton(
              onPressed: busy ? null : check,
              child: const Text('Check status'),
            ),
          if (uncertain)
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context, false),
              child: const Text('Close, keep outcome unconfirmed'),
            ),
          if (!uncertain)
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      try {
                        widget.bridge.assignmentDismiss();
                      } catch (_) {}
                      Navigator.pop(context, state == 'assigned');
                    },
              child: Text(state == 'assigned' ? 'Done' : 'Close'),
            ),
        ],
      ),
    );
  }
}
