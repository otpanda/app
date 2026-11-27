import 'package:material_ui/material_ui.dart';

import 'device_brand_icon.dart';
import 'recovery_contract.dart';
import 'settings_hub.dart'
    show RedactedText, StableText, settingsDialogConstraints;

const _emailCopy = [
  'On. If you lose every passkey and device, you can regain access with only your email after a 7-day wait.',
  'Turn off extra verification on new devices first. The two cannot be on together, and neither changes the other.',
  'Off. Turn on only if you could lose every passkey and device. A 7-day wait always applies.',
];

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
        constraints: settingsDialogConstraints,
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
          constraints: settingsDialogConstraints,
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

  Future<void> renamePasskey(RecoveryPasskey p) async {
    final c = TextEditingController(text: p.label ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        title: const Text('Name this passkey'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: passkeyLabelMax,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: p.provider ?? 'Passkey',
            helperText: 'Only shown to you. Leave empty to remove the name.',
            helperMaxLines: 3,
          ),
          onSubmitted: (_) => Navigator.pop(d, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(d, true),
            icon: const Icon(Icons.check),
            label: const Text('Save'),
          ),
        ],
      ),
    );
    // Not disposed here: the closing dialog still draws with it.
    final name = c.text.trim();
    if (ok != true || !mounted) return;
    final next = name.isEmpty ? null : name;
    if (next == p.label) return;
    await act(
      () => (widget.bridge as PasskeyLabelBridge).renamePasskey(p.id, next),
      next == null ? 'Name removed.' : 'Name saved.',
    );
  }

  /// The only passkey cannot be removed: say why only when asked.
  Future<void> explainLastPasskey() => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      constraints: const BoxConstraints(maxWidth: 400),
      title: const Text('This is your only passkey'),
      content: const Text(
        'Removing a passkey needs a different passkey of yours to confirm, so your only passkey cannot be removed. Add another passkey first.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('OK'),
        ),
      ],
    ),
  );

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
          title: Text(p.title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The provider is a hint, so it sits under a name the person set.
              if (p.label != null && p.provider != null) Text(p.provider!),
              Text('Added ${recoveryDate(p.createdAt)}'),
              Text(
                p.lastUsedAt == null
                    ? 'Not used yet'
                    : 'Last used ${recoveryDate(p.lastUsedAt!)}',
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.bridge is PasskeyLabelBridge)
                IconButton(
                  tooltip: 'Rename passkey',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: busy ? null : () => renamePasskey(p),
                ),
              IconButton(
                tooltip: 'Remove passkey',
                icon: const Icon(Icons.delete_outline),
                onPressed: busy
                    ? null
                    : s.passkeys.length < 2
                    ? explainLastPasskey
                    : () => removePasskey(p),
              ),
            ],
          ),
        ),
      if (s.passkeys.isEmpty)
        const Text(
          'Add a passkey before changing recovery settings or signing out another device.',
          style: TextStyle(fontSize: 12),
        ),
    ];
    final deviceKids = <Widget>[
      for (final d in s.sessions)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: DeviceBrandIcon(
            brand: deviceBrandOf(d),
            fallback: d.clientKind == 'android'
                ? Icons.phone_android
                : Icons.language,
          ),
          title: Text(d.title),
          subtitle: Text(
            [
                  if (d.current) 'This device',
                  'signed in ${recoveryDate(d.createdAt)}',
                  if (d.lastUsedAt != null)
                    'last used ${recoveryDate(d.lastUsedAt!)}',
                ]
                .join(', ')
                .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase()),
          ),
          trailing: d.current
              ? null
              : IconButton(
                  tooltip: 'Sign out this device',
                  icon: const Icon(Icons.logout),
                  onPressed: busy ? null : () => signOutDevice(d),
                ),
        ),
    ];
    final emailKids = <Widget>[
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Email-only recovery'),
        subtitle: StableText(
          shown: s.escapeEnabled
              ? 'On. If you lose every passkey and device, you can regain access with only your email after a ${s.delayDays}-day wait.'
              : s.blockedByGoogleProtection
              ? _emailCopy[1]
              : 'Off. Turn on only if you could lose every passkey and device. A ${s.delayDays}-day wait always applies.',
          versions: [
            _emailCopy[0].replaceAll('7-day', '${s.delayDays}-day'),
            _emailCopy[1],
            _emailCopy[2].replaceAll('7-day', '${s.delayDays}-day'),
          ],
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

  List<Widget> loadingGroups() {
    final card = widget.sectionCard;
    if (card == null) return const [];
    return [
      if (widget.sections.contains(RecoverySection.emailRecovery) ||
          widget.beforeEmailRecovery != null)
        card('Protection', [
          ?widget.beforeEmailRecovery,
          const SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Email-only recovery'),
            subtitle: StableText(shown: null, versions: _emailCopy),
            value: false,
            onChanged: null,
          ),
          if (!widget.bridge.enrolledClientApprovalAvailable)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: RedactedText(
                'Approving a change from another enrolled device is not available yet.',
                fontSize: 12,
              ),
            ),
        ]),
      if (widget.sections.contains(RecoverySection.passkeys))
        card('Passkeys', const [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: RedactedText('Passkey added 5 Nov 2026, 10:38'),
            subtitle: RedactedText('Last used 25 Nov 2026, 09:38'),
          ),
        ]),
      if (widget.sections.contains(RecoverySection.devices))
        card('Signed-in devices', const [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: RedactedText('Signed in 19 Nov 2026, 10:44'),
            subtitle: RedactedText('web, last used 25 Nov 2026, 07:44'),
          ),
        ]),
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
        if (busy && s == null && widget.sectionCard == null)
          const LinearProgressIndicator(),
        if (s == null) ...loadingGroups(),
        if (failed)
          Row(
            children: [
              const Expanded(child: Text('Recovery settings could not load.')),
              OutlinedButton.icon(
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
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
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => cancelRequest(s.request!),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel recovery request'),
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
