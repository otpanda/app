import 'dart:async';

import 'browser_session_contract.dart';
import 'assignment_dialog.dart';
import 'entry_manage_dialog.dart';
import 'totp_enrollment.dart';
import 'gmail_source.dart';
import 'read_workspace_controller.dart';

import 'package:material_ui/material_ui.dart';

import 'branding.dart';
import 'profile_header.dart';
import 'page_reload_stub.dart'
    if (dart.library.js_interop) 'page_reload_web.dart'
    as platform;
import 'main.dart' show green;
import 'pull_to_refresh.dart';
import 'session_contract.dart';

/// Read-only everyday shell for a signed-in account, backed by [CodeStore].
/// Loading, failure and a successfully loaded empty account are distinct
/// states. No fixture data is ever shown here. Mutations are not offered
/// until their endpoints exist.
class ProductShell extends StatefulWidget {
  final ReadWorkspaceController controller;
  final Future<void> Function(ReceivedCode) onCopyAssigned;
  final Future<void> Function(UnassignedCode) onCopyPrivate;
  final int Function() clock;
  final VoidCallback onSignedOut;
  final VoidCallback? onOpenAccount;
  final String? profileEmail, profilePicture;

  /// Offer "Assign" on private codes. Off unless the surface is a real
  /// account with the assignment ceremony mounted.
  final bool assignmentEnabled;

  /// Offer "Edit" on owned entries. Off until the rename/account routes are
  /// mounted and verified for the real account.
  final bool entryEditEnabled;
  final int initialTab;
  final ValueChanged<int>? onTabChanged;

  /// Pull-down action on the web: reload the whole page. Null on native
  /// clients, which refresh their data in place instead.
  final Future<void> Function()? pageReload;
  const ProductShell({
    super.key,
    required this.controller,
    required this.onCopyAssigned,
    required this.onCopyPrivate,
    required this.clock,
    required this.onSignedOut,
    this.onOpenAccount,
    this.profileEmail,
    this.profilePicture,
    this.assignmentEnabled = false,
    this.entryEditEnabled = false,
    this.initialTab = 0,
    this.onTabChanged,
    this.pageReload = platform.pageReload,
  });
  @override
  State<ProductShell> createState() => _ProductShellState();
}

enum _Phase { loading, loaded, cleared, failed, rateLimited, signedOut }

class _ProductShellState extends State<ProductShell> {
  static const names = ['Codes', 'Sources', 'Unassigned', 'Entries'];
  static const icons = [
    Icons.password,
    Icons.inbox_outlined,
    Icons.crop_free,
    Icons.list,
  ];
  static const ink = Color(0xff12281f), muted = Color(0xff5d746a);
  static const line = Color(0xffe0e8e3);
  _Phase get phase => !widget.controller.signedIn
      ? _Phase.signedOut
      : widget.controller.hasLoaded
      ? _Phase.loaded
      : widget.controller.loading
      ? _Phase.loading
      : widget.controller.message.isNotEmpty
      ? (widget.controller.rateLimited ? _Phase.rateLimited : _Phase.failed)
      : _Phase.cleared;
  late int tab = widget.initialTab.clamp(0, 3);
  String query = '';
  final searchController = TextEditingController();

  /// Search only filters Codes and Entries.
  bool get searchable => tab == 0 || tab == 3;

  void clearSearch() {
    query = '';
    searchController.clear();
  }

  void selectTab(int i) => setState(() {
    tab = i;
    widget.onTabChanged?.call(i);
    clearSearch();
  });

  /// Codes that arrived this recently sit on top, highlighted.
  static const freshForMs = 120000;
  Timer? freshTimer;
  bool hadFresh = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    // Lets the highlight fade on its own without any refresh.
    freshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && hadFresh) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant ProductShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      tab = widget.initialTab.clamp(0, 3);
      clearSearch();
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    freshTimer?.cancel();
    widget.controller.removeListener(changed);
    searchController.dispose();
    super.dispose();
  }

  Future<void> refresh() => widget.controller.refresh();

  /// Mobile-web pull reloads the document. Native hosts have no pageReload
  /// callback and never install the pull wrapper.
  Future<void> pull() async {
    await widget.pageReload?.call();
  }

  String spaced(String c) =>
      c.length == 6 ? '${c.substring(0, 3)} ${c.substring(3)}' : c;

  Widget avatar(String name) => Container(
    width: 36,
    height: 36,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xffdff3e8),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      name.isEmpty ? '?' : name[0].toUpperCase(),
      style: const TextStyle(fontWeight: FontWeight.w800, color: ink),
    ),
  );

  Widget codeTile(
    String title,
    String sub,
    String? code, [
    VoidCallback? onCopy,
    bool showCodeStatus = true,
    bool fresh = false,
    Widget? trailing,
  ]) => Card(
    key: fresh ? Key('fresh-$title-${code ?? ''}') : null,
    color: fresh ? const Color(0xffe6f5ec) : null,
    shape: fresh
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: green, width: 1.2),
          )
        : null,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          avatar(title),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                if (sub.isNotEmpty)
                  Text(
                    sub,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
              ],
            ),
          ),
          if (code != null) ...[
            const SizedBox(width: 6),
            Text(
              spaced(code),
              style: const TextStyle(
                fontFamily: 'Figtree',
                fontFeatures: [FontFeature.tabularFigures()],
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Copy code',
              onPressed: onCopy,
              icon: const Icon(Icons.copy_outlined, size: 18),
            ),
          ] else if (showCodeStatus) ...[
            const SizedBox(width: 12),
            const Text(
              'No active code',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ],
          if (trailing != null) ...[const SizedBox(width: 4), trailing],
        ],
      ),
    ),
  );

  Widget empty(String title, String body) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(body),
        ],
      ),
    ),
  );

  Widget body() {
    if (phase == _Phase.loading) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (phase == _Phase.signedOut) return const SizedBox.shrink();
    if (phase == _Phase.cleared) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Updating your codes automatically',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                'Codes were cleared from this view. Your account data has not been deleted.',
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      );
    }

    if (phase != _Phase.loaded) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                phase == _Phase.rateLimited
                    ? 'Too many requests'
                    : 'Could not load your codes',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                phase == _Phase.rateLimited
                    ? 'Updates will retry automatically in a moment.'
                    : 'Waiting for your connection. Updates will retry automatically.',
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      );
    }
    final now = widget.clock();
    final store = widget.controller.store;
    final q = query.trim().toLowerCase();
    bool match(ManagedEntry e) =>
        '${e.service} ${e.account}'.toLowerCase().contains(q);
    final entries = store.entries.where(match).toList();
    final codes = {for (final c in store.visibleCodes(now)) c.entryId: c};
    switch (tab) {
      case 0:
        final unassigned = store.visibleUnassigned(now);
        if (store.entries.isEmpty && unassigned.isEmpty) {
          return empty(
            'No codes yet',
            'Add an authenticator to generate codes, or connect a source.',
          );
        }
        bool isFresh(int receivedAt) => now - receivedAt < freshForMs;
        // Received codes (SMS, email), not generated TOTP codes.
        final freshEntries = [
          for (final e in entries)
            if (!e.totp &&
                codes[e.id] != null &&
                isFresh(codes[e.id]!.receivedAt))
              e,
        ];
        final freshPrivate = [
          for (final c in unassigned)
            if (isFresh(c.receivedAt) && q.isEmpty) c,
        ];
        hadFresh = freshEntries.isNotEmpty || freshPrivate.isNotEmpty;
        final freshIds = {for (final e in freshEntries) e.id};
        final withCode = entries.where(
          (e) => codes.containsKey(e.id) && !freshIds.contains(e.id),
        );
        final rest = entries.where((e) => !codes.containsKey(e.id));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hadFresh)
              const Padding(
                key: Key('fresh-heading'),
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Just arrived',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: green,
                  ),
                ),
              ),
            for (final c in freshPrivate)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: codeTile(
                  'Unassigned code',
                  'Only you',
                  c.value,
                  () => widget.onCopyPrivate(c),
                  true,
                  true,
                ),
              ),
            for (final e in freshEntries)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: codeTile(
                  e.service,
                  e.account,
                  codes[e.id]!.value,
                  () => widget.onCopyAssigned(codes[e.id]!),
                  true,
                  true,
                ),
              ),
            for (final e in withCode)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: codeTile(
                  e.service,
                  e.account,
                  codes[e.id]?.value,
                  () => widget.onCopyAssigned(codes[e.id]!),
                ),
              ),
            for (final e in rest)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap:
                      e.totp && widget.controller.bridge is TotpManagementBridge
                      ? () => showDialog<void>(
                          context: context,
                          builder: (_) => TotpEntryDialog(
                            bridge: widget.controller.bridge,
                            entryId: e.id,
                          ),
                        )
                      : null,
                  child: codeTile(e.service, e.account, null),
                ),
              ),
            if (entries.isEmpty && freshPrivate.isEmpty)
              const Text('Nothing matches your search.'),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.controller.bridge is GmailSourceBridge)
              GmailSourceConnect(
                bridge: widget.controller.bridge as GmailSourceBridge,
                onOpenAccount: widget.onOpenAccount,
              ),
            if (store.sources.isEmpty)
              empty(
                'No sources yet',
                'Phones and mailboxes that send codes to your account appear here.',
              ),
            for (final s in store.sources)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    codeTile(s.label, s.kind.toUpperCase(), null, null, false),
                    if (s.kind == 'gmail' &&
                        widget.controller.bridge is GmailSourceBridge)
                      GmailSourceDisconnect(
                        bridge: widget.controller.bridge as GmailSourceBridge,
                        sourceId: s.id,
                        label: s.label,
                        onChanged: () => widget.controller.refresh(),
                      ),
                  ],
                ),
              ),
          ],
        );
      case 2:
        final list = store.visibleUnassigned(now);
        final canAssign =
            widget.assignmentEnabled &&
            widget.controller.bridge is AssignmentBridge &&
            store.entries.any((e) => e.manage);
        if (list.isEmpty) {
          return empty(
            'Nothing waiting',
            'Codes that need an account match show up here.',
          );
        }
        return Column(
          children: [
            for (final c in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: codeTile(
                  'Unassigned code',
                  'Only you',
                  c.value,
                  () => widget.onCopyPrivate(c),
                  true,
                  false,
                  canAssign
                      ? IconButton(
                          key: Key('assign-${c.eventId}'),
                          tooltip: 'Assign to an entry',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => assign(c),
                          icon: const Icon(Icons.drive_file_move_outline),
                        )
                      : null,
                ),
              ),
          ],
        );
      default:
        if (store.entries.isEmpty) {
          return empty(
            'No entries yet',
            'Your services and accounts appear here.',
          );
        }
        return Column(
          children: [
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: codeTile(
                  e.service,
                  e.account,
                  null,
                  null,
                  false,
                  false,
                  editable(e)
                      ? IconButton(
                          key: Key('edit-${e.id}'),
                          tooltip: 'Edit entry',
                          onPressed: () => editEntry(e),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        )
                      : null,
                ),
              ),
          ],
        );
    }
  }

  /// Pick one owned entry, then hand the irreversible confirmation (with its
  /// passkey step) to [AssignmentDialog]. Nothing is assigned before that.
  Future<void> assign(UnassignedCode code) async {
    final raw = widget.controller.bridge;
    if (!widget.assignmentEnabled || raw is! AssignmentBridge) return;
    final AssignmentBridge bridge = raw as AssignmentBridge;
    final store = widget.controller.store;
    if (!code.active(widget.clock())) return;
    if (['unknown', 'pending', 'submitting'].contains(bridge.assignmentState)) {
      // A previous attempt is unresolved: reconcile it, send nothing new.
      final done = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AssignmentDialog(
          bridge: bridge,
          sourceId: '',
          eventId: '',
          entryId: '',
        ),
      );
      if (done == true && mounted) {
        widget.controller.refreshAfterMutation();
      }
      return;
    }
    final owned = store.entries.where((e) => e.manage).toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('assign-picker'),
        title: const Text('Choose an entry'),
        children: [
          for (final e in owned)
            SimpleDialogOption(
              key: Key('assign-to-${e.id}'),
              onPressed: () => Navigator.pop(context, e.id),
              child: Text(
                e.account.isEmpty ? e.service : '${e.service} · ${e.account}',
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const Key('assign-picker-cancel'),
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted ||
        target == null ||
        !code.active(widget.clock()) ||
        !store.visibleUnassigned(widget.clock()).contains(code) ||
        !store.entries.any((e) => e.id == target && e.manage)) {
      return;
    }
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AssignmentDialog(
        bridge: bridge,
        sourceId: code.sourceId,
        eventId: code.eventId,
        entryId: target,
      ),
    );
    if (done == true && mounted) {
      widget.controller.refreshAfterMutation();
    }
  }

  bool editable(ManagedEntry e) =>
      widget.entryEditEnabled &&
      e.manage &&
      widget.controller.bridge is EntryManagementBridge;

  Future<void> editEntry(ManagedEntry e) async {
    if (!editable(e)) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => EntryManageDialog(
        bridge: widget.controller.bridge as EntryManagementBridge,
        entry: e,
        onConfirmed: ({service, account}) => widget.controller.applyEntryEdit(
          e.id,
          service: service,
          account: account,
        ),
      ),
    );
    if (changed == true && mounted) {
      widget.controller.refreshAfterMutation();
    }
  }

  Future<void> addAuthenticator() async {
    if (!await totpPrerequisite(
          context,
          widget.controller.bridge,
          widget.onOpenAccount,
        ) ||
        !mounted) {
      return;
    }
    final id = await addTotpDialog(
      context,
      widget.controller.bridge as TotpManagementBridge,
    );
    if (id != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) =>
            TotpEntryDialog(bridge: widget.controller.bridge, entryId: id),
      );
      widget.controller.resume();
      await widget.controller.refresh();
    }
  }

  Widget searchField(bool compact) => Semantics(
    label: 'Search services or accounts',
    child: TextField(
      key: ValueKey('search-$tab'),
      controller: searchController,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: compact ? 'Search' : 'Search services or accounts',
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                key: const Key('search-clear'),
                tooltip: 'Clear search',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(clearSearch),
              ),
        filled: true,
        fillColor: const Color(0xfff2f5f3),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          borderSide: BorderSide(color: green, width: 1.5),
        ),
      ),
      onChanged: (v) => setState(() => query = v),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final desktop = size.maxWidth > 700;
      final list = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          desktop ? 0 : 12,
          desktop ? 20 : 14,
          desktop ? 0 : 12,
          30,
        ),
        children: [
          body(),
          const SizedBox(height: 20),
          if (widget.controller.connectionLost) ...[
            const Text('Connection to the server was lost. Reload the page.'),
            if (widget.pageReload != null)
              TextButton.icon(
                key: const Key('connection-reload'),
                onPressed: () => widget.pageReload!.call(),
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
              ),
          ],
          if (widget.controller.bridge is TotpManagementBridge)
            const SizedBox(height: 80),
        ],
      );
      final content = widget.pageReload == null
          ? list
          : PullToRefresh(onRefresh: pull, child: list);
      return Scaffold(
        floatingActionButton: widget.controller.bridge is TotpManagementBridge
            ? FloatingActionButton.extended(
                tooltip: 'Add authenticator',
                backgroundColor: green,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.add),
                label: const Text('Add authenticator'),
                onPressed: addAuthenticator,
              )
            : null,
        body: SafeArea(
          child: Column(
            children: [
              Container(
                key: const Key('product-top-bar'),
                height: desktop ? 76 : 64,
                padding: EdgeInsets.symmetric(horizontal: desktop ? 32 : 16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: line)),
                ),
                child: Row(
                  children: [
                    Image.memory(ottyImage, width: 42, height: 42),
                    if (desktop) ...[
                      const SizedBox(width: 8),
                      const Text(
                        'OTPanda',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontFamily: 'BricolageGrotesque',
                          fontSize: 23,
                          letterSpacing: -1,
                          color: ink,
                        ),
                      ),
                    ],
                    SizedBox(width: desktop ? 32 : 10),
                    Expanded(
                      child: Align(
                        alignment: desktop
                            ? Alignment.centerLeft
                            : Alignment.center,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: desktop ? 560 : double.infinity,
                          ),
                          child: phase == _Phase.loaded && searchable
                              ? searchField(!desktop)
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    SizedBox(width: desktop ? 16 : 6),
                    IconButton(
                      tooltip: 'Account & security',
                      onPressed: widget.onOpenAccount,
                      icon: widget.profileEmail == null
                          ? const SizedBox(
                              key: ValueKey('home-profile-loading'),
                              width: 32,
                              height: 32,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: line,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : ProfileAvatar(
                              key: ValueKey(widget.profileEmail),
                              email: widget.profileEmail!,
                              googlePicture: widget.profilePicture,
                              size: 32,
                              allowGravatar: false,
                            ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: desktop
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 232,
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    24,
                                    22,
                                    18,
                                    0,
                                  ),
                                  child: Column(
                                    children: [
                                      for (var i = 0; i < names.length; i++)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: ListTile(
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(9),
                                            ),
                                            selected: tab == i,
                                            selectedTileColor: const Color(
                                              0xffe9f8f0,
                                            ),
                                            selectedColor: const Color(
                                              0xff0a7955,
                                            ),
                                            leading: Icon(icons[i], size: 18),
                                            title: Text(names[i]),
                                            onTap: () => selectTab(i),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              Expanded(child: content),
                              const SizedBox(width: 24),
                            ],
                          )
                        : content,
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: desktop
            ? null
            : NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: selectTab,
                destinations: [
                  for (var i = 0; i < names.length; i++)
                    NavigationDestination(
                      icon: Icon(icons[i]),
                      label: names[i],
                    ),
                ],
              ),
      );
    },
  );
}
