import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'rule_action_contract.dart';

/// Call only from an explicitly enabled real-account surface, never fixtures.
class RuleActionDialog extends StatefulWidget {
  final RuleBridge bridge;
  final Map<String, dynamic> target;
  const RuleActionDialog({
    super.key,
    required this.bridge,
    required this.target,
  });
  @override
  State<RuleActionDialog> createState() => _RuleActionDialogState();
}

class _RuleActionDialogState extends State<RuleActionDialog> {
  String state = 'loading';
  Map<String, dynamic>? summary;
  bool proof = true;
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
    final current = widget.bridge.ruleState;
    if (['unknown', 'pending', 'submitting'].contains(current)) {
      state = current;
      busy = false;
    } else {
      prepare();
    }
  }

  Future<void> prepare() async {
    try {
      final text = await widget.bridge.rulePrepare(jsonEncode(widget.target));
      if (text.length > 8192) throw const FormatException();
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> ||
          value['entryId'] != widget.target['entryId'] ||
          value['irreversible'] != false ||
          value['label'] is! String ||
          value['futureRecipients'] is! int ||
          value['futureAutomations'] is! int) {
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
      result = await widget.bridge.ruleConfirm();
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
      result = await widget.bridge.ruleReconcile();
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
        title: const Text('Confirm matching rule'),
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
                Text(ruleDisclosure(s)),
              ],
              const SizedBox(height: 12),
              if (busy) const CircularProgressIndicator(),
              Text(switch (state) {
                'loading' => 'Checking the selected entry…',
                'confirm' =>
                  proof
                      ? 'Check the account and recipients before confirming with your passkey.'
                      : 'This entry is not shared with anyone. Check it before confirming.',
                'authenticating' =>
                  proof
                      ? 'Complete the passkey prompt. Do not submit again.'
                      : 'Saving the rule. Do not submit again.',
                'applied' => 'Rule confirmed for future matching codes.',
                'applied-unavailable' =>
                  'Rule change was applied. Its details could not be loaded right now. Reopen the account Details to see the current rule.',
                'not-applied' => 'Server confirmed the rule was not changed.',
                'pending' =>
                  'Rule confirmation is pending. No new request has been sent.',
                'unknown' => 'Could not confirm the outcome. It may have happened. Check status or sign in again and review the entry before trying another rule change.',
                'cancelled' =>
                  'Confirmation cancelled. No rule change was sent.',
                'expired' => 'Confirmation expired. Close and start again.',
                'paused' => 'An identical rule is paused. It has not been resumed. Close and choose Resume for that rule.',
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
              child: Text(proof ? 'Confirm with passkey' : 'Confirm'),
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
                        widget.bridge.ruleDismiss();
                      } catch (_) {}
                      Navigator.pop(
                        context,
                        state == 'applied' || state == 'applied-unavailable',
                      );
                    },
              child: Text(
                state == 'applied' || state == 'applied-unavailable'
                    ? 'Done'
                    : 'Close',
              ),
            ),
        ],
      ),
    );
  }
}
