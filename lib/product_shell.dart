import 'read_workspace_controller.dart';

import 'package:material_ui/material_ui.dart';

import 'branding.dart';
import 'page_reload_stub.dart'
    if (dart.library.js_interop) 'page_reload_web.dart'
    as platform;
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
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
  }

  @override
  void didUpdateWidget(covariant ProductShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) {
      tab = widget.initialTab.clamp(0, 3);
      query = '';
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    super.dispose();
  }

  Future<void> refresh() => widget.controller.refresh();

  /// Pull-down gesture. Honors the same gate as automatic updates
  /// (signed in, not loading, 15s gap, 429 cooldown), so it can never add
  /// requests or reloads beyond what the button allows.
  Future<void> pull() async {
    if (!widget.controller.canRefresh) return;
    final reload = widget.pageReload;
    if (reload != null) {
      await reload();
    } else {
      await widget.controller.refresh();
    }
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
  ]) => Card(
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
                fontFamily: 'monospace',
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
          ] else if (showCodeStatus)
            const Text(
              'No active code',
              style: TextStyle(fontSize: 12, color: muted),
            ),
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
        if (store.entries.isEmpty && store.visibleUnassigned(now).isEmpty) {
          return empty(
            'No codes yet',
            'Your connected sources and entries will appear here. Source setup is not available in this read-only release.',
          );
        }
        final withCode = entries.where((e) => codes.containsKey(e.id));
        final rest = entries.where((e) => !codes.containsKey(e.id));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                child: codeTile(e.service, e.account, null),
              ),
            if (entries.isEmpty) const Text('Nothing matches your search.'),
          ],
        );
      case 1:
        if (store.sources.isEmpty) {
          return empty(
            'No sources yet',
            'Phones and mailboxes that send codes to your account appear here.',
          );
        }
        return Column(
          children: [
            for (final s in store.sources)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: codeTile(
                  s.label,
                  s.kind.toUpperCase(),
                  null,
                  null,
                  false,
                ),
              ),
          ],
        );
      case 2:
        final list = store.visibleUnassigned(now);
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
                child: codeTile(e.service, e.account, null, null, false),
              ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final desktop = size.maxWidth > 700;
      final list = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          desktop ? 0 : 12,
          20,
          desktop ? 0 : 12,
          30,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tab == 0 ? 'Your codes' : names[tab],
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 28,
                    letterSpacing: -0.8,
                    color: ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (phase == _Phase.loaded && (tab == 0 || tab == 3)) ...[
            TextField(
              key: ValueKey(tab),
              decoration: const InputDecoration(
                hintText: 'Search services or accounts',
                prefixIcon: Icon(Icons.search, size: 20),
                filled: true,
                fillColor: Colors.white,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide(color: line),
                ),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            const SizedBox(height: 14),
          ],
          body(),
          const SizedBox(height: 20),
          Text(
            widget.controller.message.isNotEmpty
                ? 'Connection interrupted. Updates will retry automatically.'
                : 'Updates arrive automatically.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ],
      );
      final content = PullToRefresh(onRefresh: pull, child: list);
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Container(
                height: desktop ? 76 : 64,
                padding: EdgeInsets.symmetric(horizontal: desktop ? 32 : 16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: line)),
                ),
                child: Row(
                  children: [
                    Image.memory(ottyImage, width: 42, height: 42),
                    const SizedBox(width: 8),
                    const Text(
                      'OTPanda',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 23,
                        letterSpacing: -1,
                        color: ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Account & security',
                      onPressed: widget.onOpenAccount,
                      icon: const Icon(Icons.account_circle_outlined, size: 26),
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
                                            onTap: () => setState(() {
                                              tab = i;
                                              widget.onTabChanged?.call(i);
                                              query = '';
                                            }),
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
                onDestinationSelected: (i) => setState(() {
                  tab = i;
                  widget.onTabChanged?.call(i);
                  query = '';
                }),
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
