import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'management_contract.dart';
import 'profile_header.dart';
import 'session_contract.dart';
import 'sharing_contract.dart';

/// Sharing and machine-access page, mounted only by an explicit sharing client.
/// Default-off composition is not production activation.
///
/// - Share with a person: owner-made invite link, accepted while signed in.
/// - Remembered recipients: people who already accepted a share. Shown to the
///   owner only, with name, picture and email. Share again needs no new link.
/// - Machine access: profiles with all / selected / all-except-selected
///   accounts, and tokens with a one-year default or never expires.
///
/// Machine profiles and token metadata are loaded from the API, so they
/// survive a reload. A token secret is shown once at creation and never again.
/// A profile may name entries the viewer owns and entries delegated to them
/// with machine permission. Machine code reads stay one account and one code
/// per source; that is enforced by the API and is not configured here.
class SharingPage extends StatefulWidget {
  final SharingClient client;

  /// Entries the viewer owns. Only these can be named in a share.
  final List<ManagedEntry> entries;
  final Future<void> Function(String text) copy;
  final DateTime Function() now;
  const SharingPage({
    super.key,
    required this.client,
    required this.entries,
    this.copy = _clipboard,
    this.now = DateTime.now,
  });
  @override
  State<SharingPage> createState() => _SharingPageState();
}

Future<void> _clipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

class _Terms {
  final AccessMode mode;
  final List<String> entryIds;
  final bool canDelegate;
  final String? name;
  const _Terms(this.mode, this.entryIds, this.canDelegate, [this.name]);
}

String modeLabel(AccessMode m) => switch (m) {
  AccessMode.all => 'All accounts',
  AccessMode.allow => 'Only selected accounts',
  AccessMode.deny => 'All except selected accounts',
};

String invitationTime(int milliseconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  const months = [
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
  final offset = d.timeZoneOffset, sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  final zone =
      'UTC$sign${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
  final time =
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  return '${d.day} ${months[d.month - 1]} ${d.year}, $time $zone';
}

String grantSummary(ContactGrant g) =>
    '${modeLabel(g.mode)}${g.canDelegate ? ', can share with their machines' : ''}';

class _SharingPageState extends State<SharingPage> {
  List<SharingContact>? contacts;
  List<PendingInvite> invites = const [];
  String loadError = '', notice = '';
  bool busy = false;
  List<MachineProfileInfo>? machineProfiles;
  List<MachineEntry> machineEntries = const [];
  String machineError = '';

  @override
  void initState() {
    super.initState();
    load();
    loadMachine();
  }

  Future<void> loadMachine() async {
    setState(() => machineError = '');
    try {
      final profiles = await widget.client.listProfiles();
      final entries = await widget.client.listMachineEntries();
      if (mounted) {
        setState(() {
          machineProfiles = profiles;
          machineEntries = entries;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => machineError = 'Could not load machine access.');
      }
    }
  }

  Future<void> load() async {
    setState(() => loadError = '');
    try {
      final list = await widget.client.listContacts();
      final pending = await widget.client.listInvites();
      if (mounted) {
        setState(() {
          contacts = list;
          invites = pending;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loadError = 'Could not load people.');
    }
  }

  String _failure(Object e) => e is MutationUnconfirmed
      ? e.toString()
      : e is ClientFailure && e.status == 429
      ? 'Too many changes. Try again in a minute.'
      : e is ArgumentError
      ? 'Check the choices and try again.'
      : 'That did not work. Check the choices and try again.';

  /// Runs one change. Never retries. Reloads people afterwards whatever happened.
  Future<T?> _run<T>(Future<T> Function() change) async {
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      return await change();
    } catch (e) {
      if (mounted) setState(() => notice = _failure(e));
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
      await load();
      await loadMachine();
    }
  }

  Future<_Terms?> _askTerms(
    String title,
    String confirm, {
    bool delegation = true,
    _Terms? initial,
  }) => showDialog<_Terms>(
    context: context,
    builder: (_) => _TermsDialog(
      title: title,
      confirm: confirm,
      entries: widget.entries,
      delegation: delegation,
      initial: initial,
    ),
  );

  Future<void> invite() async {
    final terms = await _askTerms('Invite someone', 'Create link');
    if (terms == null || !mounted) return;
    final created = await _run(
      () => widget.client.createInvite(
        mode: terms.mode,
        entryIds: terms.entryIds,
        canDelegate: terms.canDelegate,
        ttlSeconds: const Duration(days: 1).inSeconds,
      ),
    );
    if (created == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _SecretDialog(
        key: const Key('invite-link'),
        title: 'Invite link',
        secret: created.link().toString(),
        note:
            'Send this to one person. They open it while signed in to OTPanda. '
            'It works once and expires in a day. You will not see it again.',
        copy: widget.copy,
      ),
    );
  }

  Future<void> shareAgain(SharingContact c) async {
    final terms = await _askTerms(
      c.grant == null ? 'Share again' : 'Change access',
      c.grant == null ? 'Share' : 'Save',
      initial: c.grant == null
          ? null
          : _Terms(c.grant!.mode, const [], c.grant!.canDelegate),
    );
    if (terms == null || !mounted) return;
    await _run(
      () => c.grant == null
          ? widget.client.createGrantForContact(
              contactRef: c.contactRef,
              mode: terms.mode,
              entryIds: terms.entryIds,
              canDelegate: terms.canDelegate,
            )
          : widget.client.updateGrant(
              contactRef: c.contactRef,
              mode: terms.mode,
              entryIds: terms.entryIds,
              canDelegate: terms.canDelegate,
            ),
    );
  }

  Future<void> revoke(SharingContact c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('revoke-confirm'),
        title: const Text('Stop sharing?'),
        content: Text(
          '${_who(c)} loses access now, and so do their machine profiles.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('revoke-yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Stop sharing'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() => widget.client.revokeGrant(c.contactRef));
  }

  Future<void> hide(SharingContact c) =>
      _run(() => widget.client.removeContact(c.contactRef));

  String _who(SharingContact c) => c.name ?? c.email ?? 'This person';

  Future<void> newProfile() async {
    final terms = await showDialog<_Terms>(
      context: context,
      builder: (_) => _TermsDialog(
        title: 'New machine profile',
        confirm: 'Create',
        entries: [
          for (final e in machineEntries)
            ManagedEntry(
              e.entryId,
              e.label,
              e.owned
                  ? e.account
                  : (e.account.isEmpty
                        ? 'Shared with you'
                        : '${e.account} · shared with you'),
              false,
            ),
        ],
        delegation: false,
        askName: true,
      ),
    );
    final label = terms?.name ?? '';
    if (terms == null || !mounted) return;
    final id = await _run(
      () => widget.client.createProfile(
        name: label,
        mode: terms.mode,
        entryIds: terms.entryIds,
      ),
    );
    if (id == null || !mounted) return;
    await newToken(id, label);
  }

  Future<void> newToken(String profileId, String label) async {
    final choice = await showDialog<Duration?>(
      context: context,
      builder: (_) => const _ExpiryDialog(),
    );
    // A dialog dismissed without a choice pops null; "never" pops Duration.zero.
    if (choice == null || !mounted) return;
    final token = await _run(
      () => choice == Duration.zero
          ? widget.client.createMachineToken(profileId, neverExpires: true)
          : widget.client.createMachineToken(profileId, ttl: choice),
    );
    if (token == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _SecretDialog(
        key: const Key('token-secret'),
        title: 'Token for $label',
        secret: token.token,
        note:
            'Copy it now. It is shown once. A machine using it can read one '
            'code per source for one account at a time. Revoke the profile '
            'to cut it off.',
        copy: widget.copy,
      ),
    );
  }

  Future<bool> _confirm(
    String title,
    String body,
    Key yes,
    String label,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: yes,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(label),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> revokeProfile(MachineProfileInfo p) async {
    if (!await _confirm(
      'Revoke ${p.name}?',
      'Every token of this profile stops working now.',
      const Key('profile-revoke-yes'),
      'Revoke profile',
    )) {
      return;
    }
    await _run(() => widget.client.revokeProfile(p.profileId));
  }

  Future<void> revokeToken(MachineProfileInfo p, MachineTokenInfo t) async {
    if (!await _confirm(
      'Revoke this token?',
      'Only this token stops working. The profile and its other tokens keep working.',
      const Key('token-revoke-yes'),
      'Revoke token',
    )) {
      return;
    }
    await _run(() => widget.client.revokeToken(p.profileId, t.tokenId));
  }

  String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  String _tokenLine(MachineTokenInfo t) {
    final nowMs = widget.now().millisecondsSinceEpoch;
    final status = t.revokedAt != null
        ? 'Revoked'
        : t.activeAt(nowMs)
        ? 'Active'
        : 'Expired';
    final ends = t.expiresAt == null
        ? 'never expires'
        : 'expires ${_date(t.expiresAt!)}';
    return '$status, created ${_date(t.createdAt)}, $ends';
  }

  Widget _profile(BuildContext context, MachineProfileInfo p) {
    final nowMs = widget.now().millisecondsSinceEpoch;
    final active = p.tokens.where((t) => t.activeAt(nowMs)).length;
    return Card(
      key: Key('profile-${p.profileId}'),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              '${modeLabel(p.mode)}'
              '${p.mode == AccessMode.all ? '' : ', ${p.entryIds.length} listed'}',
              style: TextStyle(fontSize: 12, color: context.pal.muted),
            ),
            Text(
              p.revokedAt != null
                  ? 'Revoked'
                  : '$active active token${active == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 12, color: context.pal.muted),
            ),
            for (final t in p.tokens)
              Row(
                key: Key('token-${t.tokenId}'),
                children: [
                  Expanded(
                    child: Text(
                      _tokenLine(t),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (p.revokedAt == null && t.revokedAt == null)
                    TextButton(
                      key: Key('token-revoke-${t.tokenId}'),
                      onPressed: busy ? null : () => revokeToken(p, t),
                      child: const Text('Revoke token'),
                    ),
                ],
              ),
            if (p.revokedAt == null)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    key: Key('new-token-${p.profileId}'),
                    onPressed: busy
                        ? null
                        : () => newToken(p.profileId, p.name),
                    child: const Text('New token'),
                  ),
                  TextButton(
                    key: Key('profile-revoke-${p.profileId}'),
                    onPressed: busy ? null : () => revokeProfile(p),
                    child: const Text('Revoke profile'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = contacts;
    return ListView(
      key: const Key('sharing-page'),
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Share with people',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.pal.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'People you share with can read codes. Only you can change accounts.',
          style: TextStyle(color: context.pal.muted),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('invite-button'),
          onPressed: busy ? null : invite,
          icon: const Icon(Icons.link),
          label: const Text('Invite someone with a link'),
        ),
        const SizedBox(height: 12),
        if (invites.isNotEmpty) ...[
          Text(
            'Pending invitations',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: context.pal.ink,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Links appear only once. Revoke an unused invitation before making a replacement if its link was lost.',
          ),
          for (final invite in invites)
            ListTile(
              key: Key('pending-invite-${invite.inviteId}'),
              title: Text(modeLabel(invite.mode)),
              subtitle: Text(
                'Created ${invitationTime(invite.createdAt)}\nExpires ${invitationTime(invite.expiresAt)}${invite.canDelegate ? ' · Machine sharing allowed' : ''}',
              ),
              trailing: TextButton(
                key: Key('revoke-invite-${invite.inviteId}'),
                onPressed: busy
                    ? null
                    : () => _run(
                        () => widget.client.revokeInvite(invite.inviteId),
                      ),
                child: const Text('Revoke'),
              ),
            ),
          const SizedBox(height: 12),
        ],
        if (loadError.isNotEmpty)
          Row(
            children: [
              Expanded(child: Text(loadError, key: const Key('load-error'))),
              TextButton(
                key: const Key('load-retry'),
                onPressed: load,
                child: const Text('Try again'),
              ),
            ],
          )
        else if (list == null)
          const Center(child: CircularProgressIndicator())
        else if (list.isEmpty)
          Text(
            'People you share with will appear here, so you do not need to '
            'send them another link.',
            key: const Key('no-contacts'),
            style: TextStyle(color: context.pal.muted),
          )
        else
          for (final c in list) _contact(context, c),
        if (notice.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(notice, key: const Key('sharing-notice')),
          ),
        const SizedBox(height: 28),
        Text(
          'Machine access',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.pal.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'A profile has tokens for scripts and devices. Each read returns one '
          'code per source for one account.',
          style: TextStyle(color: context.pal.muted),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('profile-button'),
          onPressed: busy || machineProfiles == null ? null : newProfile,
          icon: const Icon(Icons.memory),
          label: const Text('New machine profile'),
        ),
        if (machineError.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: Text(machineError, key: const Key('machine-error')),
              ),
              TextButton(
                key: const Key('machine-retry'),
                onPressed: loadMachine,
                child: const Text('Try again'),
              ),
            ],
          )
        else if (machineProfiles == null)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final p in machineProfiles!) _profile(context, p),
      ],
    );
  }

  Widget _contact(BuildContext context, SharingContact c) {
    final who = _who(c);
    return Card(
      key: Key('contact-${c.contactRef}'),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Never ask a third-party avatar service about a contact's email.
                ProfileAvatar(
                  email: c.email ?? c.name ?? '?',
                  googlePicture: c.picture?.toString(),
                  size: 40,
                  allowGravatar: false,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (c.name != null && c.email != null)
                        Text(
                          c.email!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: context.pal.muted),
                        ),
                      Text(
                        c.grant == null
                            ? 'Not sharing right now'
                            : grantSummary(c.grant!),
                        style: TextStyle(
                          fontSize: 12,
                          color: context.pal.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                if (!c.hidden || c.grant != null)
                  TextButton(
                    key: Key('share-again-${c.contactRef}'),
                    onPressed: busy ? null : () => shareAgain(c),
                    child: Text(
                      c.grant == null ? 'Share again' : 'Change access',
                    ),
                  ),
                if (c.grant != null)
                  TextButton(
                    key: Key('revoke-${c.contactRef}'),
                    onPressed: busy ? null : () => revoke(c),
                    child: const Text('Stop sharing'),
                  ),
                if (!c.hidden)
                  TextButton(
                    key: Key('hide-${c.contactRef}'),
                    onPressed: busy ? null : () => hide(c),
                    child: const Text('Remove from suggestions'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TermsDialog extends StatefulWidget {
  final String title, confirm;
  final List<ManagedEntry> entries;
  final bool delegation;
  final _Terms? initial;
  final bool askName;
  const _TermsDialog({
    required this.title,
    required this.confirm,
    required this.entries,
    required this.delegation,
    this.initial,
    this.askName = false,
  });
  @override
  State<_TermsDialog> createState() => _TermsDialogState();
}

class _TermsDialogState extends State<_TermsDialog> {
  late AccessMode mode = widget.initial?.mode ?? AccessMode.all;
  late bool delegate = widget.initial?.canDelegate ?? false;
  final picked = <String>{};
  final name = TextEditingController();
  String error = '';

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void submit() {
    if (widget.askName && name.text.trim().isEmpty) {
      setState(() => error = 'Give the profile a name.');
      return;
    }
    if (mode == AccessMode.allow && picked.isEmpty) {
      setState(() => error = 'Choose at least one account.');
      return;
    }
    Navigator.pop(
      context,
      _Terms(
        mode,
        mode == AccessMode.all ? const [] : picked.toList(),
        widget.delegation && delegate,
        widget.askName ? name.text.trim() : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('terms-dialog'),
    title: Text(widget.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.askName)
              TextField(
                key: const Key('profile-name'),
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            Wrap(
              spacing: 8,
              children: [
                for (final m in AccessMode.values)
                  ChoiceChip(
                    key: Key('mode-${m.name}'),
                    label: Text(modeLabel(m)),
                    selected: mode == m,
                    onSelected: (_) => setState(() {
                      mode = m;
                      error = '';
                    }),
                  ),
              ],
            ),
            if (mode != AccessMode.all)
              for (final e in widget.entries)
                CheckboxListTile(
                  key: Key('pick-${e.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(e.service),
                  subtitle: e.account.isEmpty ? null : Text(e.account),
                  value: picked.contains(e.id),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      picked.add(e.id);
                    } else {
                      picked.remove(e.id);
                    }
                    error = '';
                  }),
                ),
            if (widget.delegation)
              SwitchListTile(
                key: const Key('delegate-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('They can share it with their machines'),
                subtitle: const Text(
                  'Their machine profiles can never reach more than you give '
                  'them, and stop when you stop sharing.',
                ),
                value: delegate,
                onChanged: (v) => setState(() => delegate = v),
              ),
            if (error.isNotEmpty) Text(error, key: const Key('terms-error')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('terms-confirm'),
        onPressed: submit,
        child: Text(widget.confirm),
      ),
    ],
  );
}

class _ExpiryDialog extends StatelessWidget {
  const _ExpiryDialog();
  static const choices = <(String, Duration)>[
    ('30 days', Duration(days: 30)),
    ('90 days', Duration(days: 90)),
    ('1 year (recommended)', Duration(days: 365)),
    ('2 years', Duration(days: 730)),
    ('Never expires', Duration.zero),
  ];
  @override
  Widget build(BuildContext context) => SimpleDialog(
    key: const Key('expiry-dialog'),
    title: const Text('Token lifetime'),
    children: [
      for (final c in choices)
        SimpleDialogOption(
          key: Key('expiry-${c.$2.inDays}'),
          onPressed: () => Navigator.pop(context, c.$2),
          child: Text(c.$1),
        ),
    ],
  );
}

class _SecretDialog extends StatefulWidget {
  final String title, secret, note;
  final Future<void> Function(String) copy;
  const _SecretDialog({
    super.key,
    required this.title,
    required this.secret,
    required this.note,
    required this.copy,
  });
  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  bool copied = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.note, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          SelectableText(widget.secret, key: const Key('secret-text')),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('secret-copy'),
        onPressed: () async {
          await widget.copy(widget.secret);
          if (mounted) setState(() => copied = true);
        },
        child: Text(copied ? 'Copied' : 'Copy'),
      ),
      FilledButton(
        key: const Key('secret-done'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  );
}
