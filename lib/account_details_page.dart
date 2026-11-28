import 'entry_rule_sources.dart';

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';

import 'browser_session_contract.dart';
import 'session_contract.dart';
import 'organization_contract.dart';

/// Routed account details. Only server-supplied metadata is shown.
class AccountDetailsPage extends StatefulWidget {
  final EntryManagementBridge? bridge;
  final VoidCallback onClose;
  final bool Function() isCurrent;
  final VoidCallback? onTags;
  final List<String> tags;
  final ManagedEntry entry;
  final OrganizationStore? organization;
  final Future<void> Function(OrganizationStore)? editTags;
  final Future<bool> Function()? onOrganizationSaved;

  /// Called as soon as the server confirms the new label or account name, so
  /// the list can show it without waiting for a reload. Not called when the
  /// outcome is unknown.
  final void Function({String? service, String? account})? onConfirmed;
  const AccountDetailsPage({
    super.key,
    required this.bridge,
    required this.entry,
    required this.onClose,
    required this.isCurrent,
    this.onTags,
    this.organization,
    this.editTags,
    this.onOrganizationSaved,
    this.tags = const [],
    this.onConfirmed,
  });
  @override
  State<AccountDetailsPage> createState() => _AccountDetailsPageState();
}

class _AccountDetailsPageState extends State<AccountDetailsPage> {
  late final name = TextEditingController(text: widget.entry.service);
  late final account = TextEditingController(text: widget.entry.account);
  bool busy = false, changed = false, uncertain = false, editing = false;
  String error = '';
  OrganizationStore? draft;
  Map<String, dynamic>? openingOrganization;
  void beginEdit() {
    final org = widget.organization;
    if (org != null) {
      openingOrganization = org.document();
      draft = OrganizationStore()
        ..restore(
          {'revision': org.revision, ...org.document(), 'ranking': <Object>[]},
          (org.document()['entries'] as List).map(
            (e) => e['entryId'] as String,
          ),
        );
    }
    setState(() => editing = true);
  }

  bool get organizationDirty =>
      draft != null &&
      openingOrganization != null &&
      jsonEncode(openingOrganization) != jsonEncode(draft!.document());
  List<String> get displayedTags => !editing || draft == null
      ? widget.tags
      : [
          for (final t in draft!.tags)
            if (draft!.preferencesFor(widget.entry.id).tagIds.contains(t.id))
              t.label,
        ];

  @override
  void dispose() {
    name.dispose();
    account.dispose();
    super.dispose();
  }

  bool get dirty =>
      organizationDirty ||
      name.text.trim() != widget.entry.service ||
      account.text.trim() != widget.entry.account;
  bool get valid => name.text.trim().isNotEmpty;

  Future<void> run(Future<void> Function() action, {bool close = false}) async {
    if (!widget.isCurrent()) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      changed = true;
      if (close && mounted && widget.isCurrent()) widget.onClose();
    } catch (_) {
      // The server may or may not have applied it: reload before retrying.
      changed = true;
      uncertain = true;
      if (mounted && widget.isCurrent()) {
        setState(
          () => error =
              'Could not confirm the change. Check the list, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (!widget.isCurrent() || busy || uncertain) return;
    setState(() {
      busy = true;
      error = '';
    });
    final confirmed = <String>[];
    bool conflict() =>
        organizationDirty &&
        jsonEncode(widget.organization!.document()) !=
            jsonEncode(openingOrganization);
    void tagConflict() {
      error =
          '${confirmed.isEmpty ? '' : '${confirmed.join(' and ')} saved. '}Tags changed elsewhere. Cancel and reopen Edit to retry tags.';
    }

    try {
      if (conflict()) {
        tagConflict();
        return;
      }
      final label = name.text.trim();
      if (label != widget.entry.service) {
        await widget.bridge!.renameEntry(widget.entry.id, label);
        if (!widget.isCurrent()) return;
        confirmed.add('Title');
        widget.onConfirmed?.call(service: label);
      }
      final acc = account.text.trim();
      if (acc != widget.entry.account) {
        await widget.bridge!.updateAccount(
          widget.entry.id,
          acc.isEmpty ? null : acc,
        );
        if (!widget.isCurrent()) return;
        confirmed.add('Login');
        widget.onConfirmed?.call(account: acc);
      }
      if (organizationDirty && widget.isCurrent()) {
        if (!widget.organization!.applyDraft(
          openingOrganization!,
          draft!.document(),
        )) {
          tagConflict();
          return;
        }
        bool saved;
        try {
          saved = await widget.onOrganizationSaved?.call() ?? false;
        } catch (_) {
          if (!widget.isCurrent()) return;
          uncertain = true;
          error =
              '${confirmed.isEmpty ? '' : '${confirmed.join(' and ')} saved. '}Could not confirm tags. Check your saved tags before editing again.';
          return;
        }
        if (!widget.isCurrent()) return;
        if (!saved) {
          error =
              '${confirmed.isEmpty ? '' : '${confirmed.join(' and ')} saved. '}Tags were not saved. Cancel and reopen Edit to check your saved tags.';
          return;
        }
      }
      if (mounted && widget.isCurrent()) widget.onClose();
    } catch (_) {
      uncertain = true;
      error =
          '${confirmed.isEmpty ? '' : '${confirmed.join(' and ')} saved. '}Could not confirm the remaining change. Check the list before trying again.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        key: const Key('entry-delete-confirm'),
        title: const Text('Delete this account?'),
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
    if (ok != true || !mounted || !widget.isCurrent()) return;
    final Object? b = widget.bridge;
    if (b is! EntryDeleteBridge) return;
    await run(() => b.deleteEntry(widget.entry.id), close: true);
  }

  void cancelEdit() {
    FocusScope.of(context).unfocus();
    setState(() {
      name.text = widget.entry.service;
      account.text = widget.entry.account;
      editing = false;
      draft = null;
      openingOrganization = null;
    });
  }

  Widget info(String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.pal.muted,
          ),
        ),
        const SizedBox(height: 8),
        value,
      ],
    ),
  );
  Widget tagChips() => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      if (editing && draft != null) ...[
        for (final tag in draft!.tags.where(
          (t) => draft!.preferencesFor(widget.entry.id).tagIds.contains(t.id),
        ))
          InputChip(
            avatar: const Icon(Icons.sell_outlined, size: 14),
            label: Text(tag.label),
            onDeleted: busy || uncertain
                ? null
                : () => setState(
                    () => draft!.setTags(
                      widget.entry.id,
                      draft!
                          .preferencesFor(widget.entry.id)
                          .tagIds
                          .where((id) => id != tag.id),
                    ),
                  ),
            deleteButtonTooltipMessage: 'Remove ${tag.label}',
          ),
      ] else ...[
        for (final tag in displayedTags)
          Chip(
            avatar: const Icon(Icons.sell_outlined, size: 14),
            label: Text(tag),
          ),
      ],
      if (editing && draft != null && widget.editTags != null)
        ActionChip(
          key: const Key('entry-tags'),
          avatar: const Icon(Icons.add, size: 16),
          label: const Text('Add tags'),
          onPressed: busy || uncertain
              ? null
              : () async {
                  await widget.editTags!(draft!);
                  if (mounted && widget.isCurrent()) setState(() {});
                },
        ),
      if (displayedTags.isEmpty && !editing)
        Text('No tags', style: TextStyle(color: context.pal.muted)),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('account-details'),
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Back to codes',
        onPressed: busy
            ? null
            : () {
                if (editing) {
                  cancelEdit();
                } else {
                  widget.onClose();
                }
              },
        icon: const Icon(Icons.arrow_back),
      ),
      title: Text(editing ? 'Edit account' : 'Account details'),
      actions: [
        if (!editing && widget.bridge != null)
          IconButton(
            key: const Key('entry-edit'),
            tooltip: 'Edit account',
            onPressed: uncertain ? null : beginEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: context.pal.field,
                            child: Text(
                              widget.entry.service.isEmpty
                                  ? '?'
                                  : widget.entry.service
                                        .substring(0, 1)
                                        .toUpperCase(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.entry.service,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (widget.entry.account.isNotEmpty)
                                  Text(
                                    widget.entry.account,
                                    style: TextStyle(color: context.pal.muted),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    info(
                      'Title',
                      editing
                          ? TextField(
                              key: const Key('entry-name'),
                              controller: name,
                              enabled: !busy && !uncertain,
                              maxLength: 120,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                isDense: true,
                                counterText: '',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 13,
                                ),
                              ),
                            )
                          : Text(
                              widget.entry.service,
                              key: const Key('entry-title-value'),
                            ),
                    ),
                    Divider(height: 1, color: context.pal.line),
                    info(
                      'Login',
                      editing
                          ? TextField(
                              key: const Key('entry-account'),
                              controller: account,
                              enabled: !busy && !uncertain,
                              maxLength: 120,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                isDense: true,
                                counterText: '',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 13,
                                ),
                              ),
                            )
                          : Text(
                              widget.entry.account.isEmpty
                                  ? 'Not set'
                                  : widget.entry.account,
                            ),
                    ),
                    if (widget.entry.totp || widget.bridge is RuleBridge) ...[
                      Divider(height: 1, color: context.pal.line),
                      info(
                        'Sources',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.entry.totp)
                              const Chip(
                                avatar: Icon(Icons.shield_outlined, size: 16),
                                label: Text('Authenticator codes'),
                              ),
                            if (widget.bridge is RuleBridge)
                              EntryRuleSources(
                                bridge: widget.bridge as RuleBridge,
                                entryId: widget.entry.id,
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (widget.entry.issuer != null) ...[
                      Divider(height: 1, color: context.pal.line),
                      info('Issuer', Text(widget.entry.issuer!)),
                    ],
                    Divider(height: 1, color: context.pal.line),
                    info('Tags', tagChips()),
                    if (widget.entry.createdAt != null) ...[
                      Divider(height: 1, color: context.pal.line),
                      info(
                        'Added',
                        Text(() {
                          final d = DateTime.fromMillisecondsSinceEpoch(
                            widget.entry.createdAt!,
                          ).toLocal();
                          return '${d.day}/${d.month}/${d.year}';
                        }()),
                      ),
                    ],
                    if (error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          error,
                          key: const Key('entry-error'),
                          style: TextStyle(color: context.pal.danger),
                        ),
                      ),
                    if (editing && widget.bridge is EntryDeleteBridge)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const Key('entry-delete'),
                            onPressed: busy || uncertain ? null : remove,
                            icon: Icon(
                              Icons.delete_outline,
                              color: context.pal.danger,
                            ),
                            label: Text(
                              'Delete account',
                              style: TextStyle(color: context.pal.danger),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (editing)
            Container(
              key: const Key('entry-edit-bar'),
              decoration: BoxDecoration(
                color: context.pal.card,
                border: Border(top: BorderSide(color: context.pal.line)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('entry-cancel'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: busy ? null : cancelEdit,
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('entry-save'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: busy || uncertain || !dirty || !valid
                            ? null
                            : save,
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
