import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';

import 'native_action_proof.dart';
import 'native_approval_routes.dart';

/// Pending approvals for an enrolled phone (inactive until wired). The text
/// comes from [approvalPrompt], the same function that feeds the OS prompt, so
/// what is read here is what the unlock vouches for. Display only.
class ApprovalListView extends StatefulWidget {
  const ApprovalListView({
    super.key,
    required this.status,
    required this.accountEmail,
    required this.clock,
    required this.onApprove,
    required this.onDismiss,
    this.busyChangeId,
    this.tick = const Duration(seconds: 15),
  });
  final ApprovalStatus status;
  final String accountEmail;

  /// Epoch ms now. Read on every build and every [tick], so ages move and
  /// expired rows disappear while the screen stays open.
  final int Function() clock;
  final void Function(ApprovalRow row) onApprove;

  /// Local only: hides the card on this phone. The server has no deny route,
  /// so the request stays open until it expires; nothing is sent.
  final void Function(ApprovalRow row) onDismiss;
  final String? busyChangeId;
  final Duration tick;

  @override
  State<ApprovalListView> createState() => _ApprovalListViewState();
}

class _ApprovalListViewState extends State<ApprovalListView> {
  Timer? _timer;
  final _dismissed = <String>{};

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.tick, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.clock();
    final rows = [
      for (final r in widget.status.pending)
        if (r.expiresAt > now && !_dismissed.contains(r.changeId)) r,
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Approval requests',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Text('Nothing is waiting for approval.')
        else
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ApprovalCard(
                row: r,
                accountEmail: widget.accountEmail,
                nowMs: now,
                busy: widget.busyChangeId == r.changeId,
                onApprove: () => widget.onApprove(r),
                onDismiss: () {
                  setState(() => _dismissed.add(r.changeId));
                  widget.onDismiss(r);
                },
              ),
            ),
      ],
    );
  }
}

class ApprovalCard extends StatelessWidget {
  const ApprovalCard({
    super.key,
    required this.row,
    required this.accountEmail,
    required this.nowMs,
    required this.onApprove,
    required this.onDismiss,
    this.busy = false,
  });
  final ApprovalRow row;
  final String accountEmail;
  final int nowMs;
  final bool busy;
  final VoidCallback onApprove, onDismiss;

  @override
  Widget build(BuildContext context) {
    final fp = row.target == null ? null : fingerprintOf(row.target!);
    final text = approvalPrompt(
      kind: row.kind,
      accountEmail: accountEmail,
      requesterLabel: row.requesterLabel,
      requesterKind: row.requesterKind,
      requestedAtMs: row.requestedAt,
      nowMs: nowMs,
      fingerprint: fp,
    );
    final title = row.kind == 'passkey-add' ? 'Add a passkey' : 'Add a phone';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.pal.card,
        border: Border.all(color: context.pal.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.pal.ink,
            ),
          ),
          const SizedBox(height: 8),
          if (text == null)
            Text(
              'This request could not be shown safely, so it cannot be approved here.',
              style: TextStyle(color: context.pal.muted),
            )
          else
            Text(text, style: TextStyle(color: context.pal.ink, height: 1.4)),
          if (fp != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: context.pal.field,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                fp,
                key: const ValueKey('fingerprint'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: context.pal.ink,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Dismiss only hides this here. The request stays open until it expires.',
            style: TextStyle(color: context.pal.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: text == null || busy ? null : onApprove,
                  style: FilledButton.styleFrom(
                    backgroundColor: context.pal.brand,
                  ),
                  child: Text(busy ? 'Waiting for unlock' : 'Approve'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onDismiss,
                  child: const Text('Dismiss'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
