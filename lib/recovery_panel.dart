import 'package:material_ui/material_ui.dart';

import 'recovery_contract.dart';

String recoveryDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  const m = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

/// Recovery controls for a signed-in account. Every change asks for a fresh
/// passkey check through the bridge; nothing here approves from another device.
enum RecoverySection { passkeys, devices, emailRecovery }

class RecoveryPanel extends StatefulWidget {
  final RecoveryBridge bridge;

  /// Which parts to show. The default shows everything under a "Recovery"
  /// title, as the panel always did. The settings pages pick their parts.
  final Set<RecoverySection> sections;

  /// Shown with the email-only recovery switch, before it.
  final Widget? beforeEmailRecovery;

  /// When set, each part is drawn as a titled card the host styles.
  final Widget Function(String title, List<Widget> children)? sectionCard;
  const RecoveryPanel({
    super.key,
    required this.bridge,
    this.sections = const {
      RecoverySection.passkeys,
      RecoverySection.devices,
      RecoverySection.emailRecovery,
    },
    this.beforeEmailRecovery,
    this.sectionCard,
  });
  bool get _all => sections.length == RecoverySection.values.length;
  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

class _RecoveryPanelState extends State<RecoveryPanel> {
  RecoveryStatus? status;
  bool busy = false, failed = false;
  String message = '';
  int epoch = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    epoch++;
    super.dispose();
  }

  Future<void> load() async {
    final mine = ++epoch;
    setState(() => busy = true);
    try {
      final s = await widget.bridge.recoveryStatus();
      if (!mounted || mine != epoch) return;
      setState(() {
        status = s;
        failed = false;
      });
    } catch (_) {
      if (!mounted || mine != epoch) return;
      setState(() {
        status = null;
        failed = true;
      });
    } finally {
      if (mounted && mine == epoch) setState(() => busy = false);
    }
  }

  Future<void> act(Future<void> Function() action, String done) async {
    final mine = ++epoch;
    setState(() {
      busy = true;
      message = '';
    });
    var result = done;
    try {
      await action();
    } on RecoveryRefused {
      // Generic on purpose: a refusal, a cancelled check and a stale change
      // look the same to the person.
      result = 'That request was not accepted. Check the lists below, then try again if needed.';
    } catch (_) {
      // Anything else could have committed. Never claim it did not.
      result = 'We could not confirm that change. It may have gone through. Check the lists below before trying again.';
    }
    if (!mounted || mine != epoch) return;
    setState(() => message = result);
    await load();
  }

  Future<bool> confirm(String title, String body, String action) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return r == true;
  }

  Future<void> enable() async {
    var accepted = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Allow email-only recovery?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'If you lose every passkey and device, you could regain access using only your email, after a ${status!.delayDays}-day wait. '
                'Anyone who controls your mailbox could also start this. You can cancel while it waits, but only from a signed-in passkey device.',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: accepted,
                onChanged: (v) => set(() => accepted = v == true),
                title: const Text(
                  'I understand this lowers protection if my email is compromised.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: accepted ? () => Navigator.pop(c, true) : null,
              child: const Text('Turn on'),
            ),
          ],
        ),
      ),
    );
    if (go != true) return;
    await act(
      () => widget.bridge.recoveryChange(
        const RecoveryChange(RecoveryKind.emailEscapeOn, warningAccepted: true),
      ),
      'Email-only recovery is on.',
    );
  }

  Future<void> disable() async {
    if (!await confirm(
      'Turn off email-only recovery?',
      'Any waiting recovery request is canceled. You will confirm with a passkey.',
      'Turn off',
    )) {
      return;
    }
    await act(
      () => widget.bridge.recoveryChange(
        const RecoveryChange(RecoveryKind.emailEscapeOff),
      ),
      'Email-only recovery is off.',
    );
  }

  Future<void> removePasskey(RecoveryPasskey p) async {
    if (!await confirm(
      'Remove this passkey?',
      'You will confirm this with a passkey. If it cannot be removed, nothing changes.',
      'Remove',
    )) {
      return;
    }
    await act(
      () => widget.bridge.recoveryChange(
        RecoveryChange(RecoveryKind.passkeyRevoke, target: p.id),
      ),
      'Passkey removed.',
    );
  }

  Future<void> signOutDevice(RecoverySession s) async {
    if (!await confirm(
      'Sign out this device?',
      'It loses access right away. Your data stays as it is.',
      'Sign out',
    )) {
      return;
    }
    await act(
      () => widget.bridge.recoveryChange(
        RecoveryChange(RecoveryKind.sessionRevoke, target: s.id),
      ),
      'Device signed out.',
    );
  }

  Future<void> cancelRequest(EmailRecoveryRequest r) => act(
    () => widget.bridge.recoveryCancelRequest(r.requestId),
    'Recovery request canceled.',
  );

  List<Widget> _groups(RecoveryStatus s) {
    final card = widget.sectionCard;
    final passkeyKids = <Widget>[
      for (final p in s.passkeys)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: card == null ? const Icon(Icons.key) : null,
          title: Text('Passkey added ${recoveryDate(p.createdAt)}'),
          subtitle: Text(
            p.lastUsedAt == null
                ? 'Not used yet'
                : 'Last used ${recoveryDate(p.lastUsedAt!)}',
          ),
          trailing: TextButton(
            onPressed: busy || s.passkeys.length < 2
                ? null
                : () => removePasskey(p),
            child: const Text('Remove'),
          ),
        ),
      Text(
        s.passkeys.isEmpty
            ? 'Add a passkey before changing recovery settings or signing out another device.'
            : s.passkeys.length < 2
            ? 'Removing a passkey needs a different passkey of yours to confirm. Your only passkey cannot be removed here. Add another passkey first.'
            : 'Removing a passkey needs a different passkey of yours to confirm.',
        style: const TextStyle(fontSize: 12),
      ),
    ];
    final deviceKids = <Widget>[
      for (final d in s.sessions)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            d.clientKind == 'android' ? Icons.phone_android : Icons.language,
          ),
          title: Text(
            d.current
                ? 'This device'
                : 'Signed in ${recoveryDate(d.createdAt)}',
          ),
          subtitle: Text(
            d.lastUsedAt == null
                ? d.clientKind
                : '${d.clientKind}, last used ${recoveryDate(d.lastUsedAt!)}',
          ),
          trailing: d.current
              ? null
              : TextButton(
                  onPressed: busy ? null : () => signOutDevice(d),
                  child: const Text('Sign out'),
                ),
        ),
    ];
    final emailKids = <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Email-only recovery'),
        subtitle: Text(
          s.escapeEnabled
              ? 'On. If you lose every passkey and device, you can regain access with only your email after a ${s.delayDays}-day wait.'
              : s.blockedByGoogleProtection
              ? 'Turn off extra verification on new devices first. The two cannot be on together, and neither changes the other.'
              : 'Off. Turn on only if you could lose every passkey and device. A ${s.delayDays}-day wait always applies.',
        ),
        value: s.escapeEnabled,
        onChanged: busy || (!s.escapeEnabled && s.blockedByGoogleProtection)
            ? null
            : (on) => on ? enable() : disable(),
      ),
      if (!widget.bridge.enrolledClientApprovalAvailable)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            'Approving a change from another enrolled device is not available yet.',
            style: TextStyle(fontSize: 12),
          ),
        ),
    ];
    final lead = widget.beforeEmailRecovery;
    final hasP = widget.sections.contains(RecoverySection.passkeys);
    final hasD = widget.sections.contains(RecoverySection.devices);
    final hasE = widget.sections.contains(RecoverySection.emailRecovery);
    if (card != null) {
      return [
        if (hasE || lead != null)
          card('Protection', [?lead, if (hasE) ...emailKids]),
        if (hasP) card('Passkeys', passkeyKids),
        if (hasD) card('Signed-in devices', deviceKids),
      ];
    }
    return [
      if (hasP) ...[
        const Text('Passkeys', style: TextStyle(fontWeight: FontWeight.w700)),
        ...passkeyKids,
      ],
      if (hasD) ...[
        const SizedBox(height: 12),
        const Text(
          'Signed-in devices',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...deviceKids,
      ],
      ?lead,
      if (hasE) ...[const SizedBox(height: 12), ...emailKids],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final s = status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget._all && widget.sectionCard == null) ...[
          const Text(
            'Recovery',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
        ],
        if (busy && s == null) const LinearProgressIndicator(),
        if (failed)
          Row(
            children: [
              const Expanded(child: Text('Recovery settings could not load.')),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('Try again'),
              ),
            ],
          ),
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(message, key: const Key('recovery-message')),
          ),
        if (s != null) ...[
          if (s.request != null)
            Card(
              key: const Key('recovery-request'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Email recovery requested',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'It can be completed from ${recoveryDate(s.request!.availableAt)}. '
                      'If this was not you, cancel it now and review your passkeys and devices.',
                    ),
                    TextButton(
                      onPressed: busy ? null : () => cancelRequest(s.request!),
                      child: const Text('Cancel recovery request'),
                    ),
                  ],
                ),
              ),
            ),
          ..._groups(s),
        ],
      ],
    );
  }
}
