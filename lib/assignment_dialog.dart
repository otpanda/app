import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'assignment_rule_contract.dart';

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
  bool proof = true;
  bool get deviceConfirmation => widget.bridge is DeviceConfirmationBridge;
  bool busy = true;
  int checks = 0;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  /// Status only, never a new begin. Bounded: 2s, 4s, 8s, 16s, then the user
  /// decides.
  void backoff() {
    if (state != 'pending' || checks >= 4 || !mounted) return;
    timer?.cancel();
    timer = Timer(Duration(seconds: 2 << checks), () {
      checks++;
      if (mounted && !busy && state == 'pending') check(auto: true);
    });
  }

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
        proof = value['proofRequired'] != false;
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
      backoff();
    }
  }

  Future<void> check({bool auto = false}) async {
    if (!auto) checks = 0;
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
      backoff();
    }
  }

  @override
  Widget build(BuildContext context) {
    final uncertain = ['unknown', 'pending', 'submitting'].contains(state);
    final s = summary;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        constraints: const BoxConstraints(maxWidth: 520),
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
                if (proof) ...[
                  Text('Active recipients: ${s['activeRecipients']}'),
                  Text(
                    'Automation access grants: ${s['automationRecipients']}',
                  ),
                ],
                if (s['rule'] is Map<String, dynamic>) ...[
                  const SizedBox(height: 12),
                  Text(
                    assignmentRuleDisclosure(s['rule'] as Map<String, dynamic>),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  proof
                      ? 'This releases this code to the selected entry. Recipients may read or save it immediately. Revoking access later cannot undo that. ${s['rule'] is Map && s['rule']['status'] == 'will_save' ? 'The future rule takes effect after confirmation.' : 'This does not assign future messages.'}'
                      : 'This moves this code into the selected entry. It cannot be undone. ${s['rule'] is Map && s['rule']['status'] == 'will_save' ? 'The future rule takes effect after confirmation.' : 'This does not assign future messages.'}',
                ),
              ],
              const SizedBox(height: 12),
              if (busy) const CircularProgressIndicator(),
              Text(switch (state) {
                'loading' => 'Checking the selected entry…',
                'confirm' =>
                  proof
                      ? (deviceConfirmation
                            ? 'Check the account and recipients before confirming with your device screen lock.'
                            : 'Check the account and recipients before confirming with your passkey.')
                      : 'This entry is not shared with anyone. Check it before confirming.',
                'authenticating' =>
                  proof
                      ? (deviceConfirmation
                            ? 'Complete the device screen-lock prompt. Do not submit again.'
                            : 'Complete the passkey prompt. Do not submit again.')
                      : 'Assigning. Do not submit again.',
                'assigned' => 'Assignment confirmed.',
                'assigned-paused' => 'Code assigned. The matching rule is still paused. Resume it separately in account Details.',
                'assigned-no-rule' =>
                  'Code assigned, but no future matching rule was saved.',
                'not-assigned' => 'Server confirmed this assignment did not happen. Close to choose an entry and start a new confirmation.',
                'pending' => 'Assignment is still pending. No new assignment has been sent.',
                'unknown' => 'Could not confirm the outcome. It may have happened. Check status or sign in again and review the entry before trying a new assignment.',
                'cancelled' => 'Passkey cancelled. No assignment was sent.',
                'expired' => 'Confirmation expired. Close and start again.',
                'idle' => 'Session changed. Sign in and review the entry. A request already sent may still have completed.',
                _ => 'This action can\'t be completed here right now. No confirmation was requested. Check your connection and try again.',
              }),
            ],
          ),
        ),
        actions: [
          if (state == 'confirm')
            FilledButton(
              onPressed: busy ? null : confirm,
              child: Text(
                proof
                    ? (deviceConfirmation
                          ? 'Confirm with device'
                          : 'Confirm with passkey')
                    : 'Confirm',
              ),
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
                      Navigator.pop(context, state.startsWith('assigned'));
                    },
              child: Text(state.startsWith('assigned') ? 'Done' : 'Close'),
            ),
        ],
      ),
    );
  }
}
