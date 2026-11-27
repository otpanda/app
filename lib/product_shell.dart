import 'rule_action_dialog.dart';

import 'dart:async';

import 'copy_hint.dart';
import 'organization_contract.dart';
import 'account_sort.dart';
import 'code_filter_row.dart';
import 'revealed_filter_list.dart';
import 'unassigned_context.dart';

import 'main_page_batch.dart';
import 'totp_batch_contract.dart';

import 'browser_session_contract.dart';
import 'assignment_dialog.dart';
import 'account_details_page.dart';
import 'detail_routes.dart';
import 'totp_enrollment.dart';
import 'read_workspace_controller.dart';

import 'package:material_ui/material_ui.dart';

import 'branding.dart';
import 'profile_header.dart';
import 'page_reload_stub.dart'
    if (dart.library.js_interop) 'page_reload_web.dart'
    as platform;
import 'app_theme.dart';
import 'refresh_bar.dart';
import 'service_logo.dart';
import 'session_contract.dart';

/// Read-only everyday shell for a signed-in account, backed by [CodeStore].
/// Loading, failure and a successfully loaded empty account are distinct
/// states. No fixture data is ever shown here. Mutations are not offered
/// until their endpoints exist.
class ProductShell extends StatefulWidget {
  final String? navigation;
  final ValueChanged<String>? onNavigate;
  final ReadWorkspaceController controller;
  final OrganizationStore? organization;
  final VoidCallback? onOrganizationChanged;
  final Future<bool> Function()? saveOrganization;
  final bool showTileTags;
  final bool organizationBusy;
  final String organizationMessage;
  final BatchPolicy? batchPolicy;
  final CopyHintStore? copyHintStore;

  /// Test seam: replaces the batch controller's monotonic and wall clocks.
  @visibleForTesting
  final int Function()? batchClock;
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
  final bool entryDomainsEnabled;

  /// Pull-down action on the web: reload the whole page. Null on native
  /// clients, which refresh their data in place instead.
  final Future<void> Function()? pageReload;
  const ProductShell({
    super.key,
    required this.controller,
    this.navigation,
    this.onNavigate,
    this.organization,
    this.onOrganizationChanged,
    this.saveOrganization,
    this.showTileTags = false,
    this.organizationBusy = false,
    this.organizationMessage = '',
    this.copyHintStore,
    this.batchPolicy,
    this.batchClock,
    required this.onCopyAssigned,
    required this.onCopyPrivate,
    required this.clock,
    required this.onSignedOut,
    this.onOpenAccount,
    this.profileEmail,
    this.profilePicture,
    this.assignmentEnabled = false,
    this.entryEditEnabled = false,
    this.entryDomainsEnabled = false,
    this.pageReload = platform.pageReload,
  });
  @override
  State<ProductShell> createState() => _ProductShellState();
}

enum _Phase { loading, loaded, cleared, failed, rateLimited, signedOut }

class _ProductShellState extends State<ProductShell>
    with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    batch?.foreground(state == AppLifecycleState.resumed);
    queueBatchSelection();
  }

  bool get _canAddTotp =>
      widget.controller.bridge is TotpManagementBridge &&
      (widget.controller.bridge is! TotpCreationCapability ||
          (widget.controller.bridge as TotpCreationCapability).canAddTotp);
  _Phase get phase => !widget.controller.signedIn
      ? _Phase.signedOut
      : widget.controller.hasLoaded
      ? _Phase.loaded
      : widget.controller.loading
      ? _Phase.loading
      : widget.controller.message.isNotEmpty
      ? (widget.controller.rateLimited ? _Phase.rateLimited : _Phase.failed)
      : _Phase.cleared;
  String? localDetailRoute;
  String? detailOwner;
  String? scheduledUnavailableRoute;
  void openDetails(String route) {
    detailOwner = widget.controller.store.ownerId;
    if (widget.onNavigate != null) {
      widget.onNavigate!(route);
    } else {
      setState(() => localDetailRoute = route);
    }
  }

  void closeDetails({bool refresh = true}) {
    if (refresh) widget.controller.refreshAfterMutation();
    if (widget.onNavigate != null) {
      widget.onNavigate!('codes');
    } else {
      setState(() => localDetailRoute = null);
    }
  }

  String query = '';
  AccountSort accountSort = AccountSort.frequentlyUsed;
  Set<String> filters = {}, selectedAccounts = {};
  final Map<String, int> localLastUsed = {};
  String? selectionOwner;
  final searchController = TextEditingController();

  /// Search only filters Codes and Entries.
  bool get searchable => true;

  void clearSearch() {
    query = '';
    searchController.clear();
  }

  /// Codes that arrived this recently sit on top, highlighted.
  static const freshForMs = 120000;
  Timer? freshTimer;
  late CopyHintStore _copyHintStore;
  bool _copyHint = false;
  bool _showCopyButton = false;
  bool _copiedThisRun = false;
  Timer? _copiedTimer;
  Timer? _boundaryTimer;
  void scheduleBoundaryRepaint() {
    _boundaryTimer?.cancel();
    final delay = batch?.nextBoundaryDelayMs;
    if (delay != null) {
      _boundaryTimer = Timer(Duration(milliseconds: delay), () {
        if (mounted) batch?.tick();
      });
    }
  }

  String? _copiedTile;

  void dismissCopyTutorial() {
    setState(() {
      _copyHint = false;
      _copiedThisRun = true;
    });
    unawaited(_copyHintStore.markCopied().catchError((Object _) {}));
  }

  bool get hasCopyableCard {
    final now = widget.clock();
    final c = widget.controller;
    final private = c.store.visibleUnassigned(now).any(c.canCopyPrivate);
    final q = query.trim().toLowerCase();
    if (q.isEmpty && private) return true;
    final codes = {
      for (final code in c.store.visibleCodes(now)) code.entryId: code,
    };
    return c.store.entries.any((e) {
      if (!'${e.service} ${e.account}'.toLowerCase().contains(q)) return false;
      if (e.totp) return batch?.tileCurrent(e.id)?.copyable ?? false;
      final code = codes[e.id];
      return code != null && c.canCopyAssigned(code);
    });
  }

  Widget copyTutorial() => Container(
    key: const Key('copy-tutorial-banner'),
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.fromLTRB(16, 14, 6, 16),
    decoration: BoxDecoration(
      color: context.pal.arrival,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: context.pal.arrivalBorder, width: 1.5),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: context.pal.brand,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            Icons.touch_app_outlined,
            color: context.pal.onBrand,
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tap a card to copy',
                style: TextStyle(
                  fontSize: 19,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  color: context.pal.arrivalInk,
                ),
              ),
              SizedBox(height: 7),
              Text(
                'Tap anywhere on a code card below, then paste it where you need it.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: context.pal.arrivalInk,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('dismiss-copy-tutorial'),
          tooltip: 'Dismiss copy tutorial',
          onPressed: dismissCopyTutorial,
          icon: Icon(Icons.close, size: 20, color: context.pal.arrivalInk),
        ),
      ],
    ),
  );

  Future<void> copyTile(String id, Future<bool> Function() copy) async {
    try {
      if (!await copy() || !mounted) return;
      final parts = id.split('/');
      final entryId =
          parts.length > 1 && (parts.first == 'entry' || parts.first == 'totp')
          ? parts[1]
          : null;
      if (entryId != null) {
        localLastUsed[entryId] = widget.clock();
        final bridge = widget.controller.bridge;
        {
          unawaited(
            bridge
                .copied(entryId, widget.clock())
                .then((_) {})
                .catchError((Object _) {}),
          );
        }
      }
      _copiedTimer?.cancel();
      setState(() {
        _copiedTile = id;
        _copyHint = false;
        _copiedThisRun = true;
      });
      unawaited(
        _copyHintStore.markCopied().catchError((Object _) {
          /* Session dismissal still holds if storage is unavailable. */
        }),
      );
      _copiedTimer = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _copiedTile = null);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not copy code.')));
      }
    }
  }

  bool hadFresh = false;
  MainPageBatchController? batch;
  final _batchKeys = <String, GlobalKey>{};
  final _batchScroll = ScrollController();
  bool _batchSelectionQueued = false;
  void queueBatchSelection() {
    if (_batchSelectionQueued) return;
    _batchSelectionQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _batchSelectionQueued = false;
      if (mounted) syncBatch();
    });
  }

  int _batchRevision = -1;
  String? _batchOwner;
  void syncBatch() {
    final b = batch;
    if (b == null) return;
    if (!widget.controller.signedIn ||
        !widget.controller.hasLoaded ||
        widget.controller.store.sessionExpired(widget.clock())) {
      b.invalidate();
      return;
    }
    final validIds = widget.controller.store.entries
        .where((e) => e.totp)
        .map((e) => e.id)
        .toSet();
    if (_batchRevision != widget.controller.publishedRevision) {
      _batchRevision = widget.controller.publishedRevision;
      final owner = widget.controller.store.ownerId;
      if (owner == null || owner != _batchOwner) {
        b.invalidate();
      }
      final changed = {
        for (final e in widget.controller.store.entries.where((e) => e.totp))
          if (e.expectedDigits != null &&
              b.expectedDigits(e.id) != null &&
              e.expectedDigits != b.expectedDigits(e.id))
            e.id,
      };
      b.retainAuthorized(validIds, changed: changed);
      _batchOwner = owner;
    }
    _batchKeys.removeWhere((id, _) => !validIds.contains(id));
    final q = query.trim().toLowerCase();
    final ids = [
      for (final e in widget.controller.store.entries)
        if (e.totp && ('${e.service} ${e.account}'.toLowerCase().contains(q)))
          e.id,
    ];
    final height = MediaQuery.sizeOf(context).height;
    double distance(String id) {
      final r = _batchKeys[id]?.currentContext?.findRenderObject();
      if (r is! RenderBox || !r.hasSize) return double.infinity;
      final y = r.localToGlobal(Offset.zero).dy;
      return y < 0
          ? -y
          : y > height
          ? y - height
          : 0;
    }

    ids.sort((a, b) => distance(a).compareTo(distance(b)));
    final near = ids.where((id) => distance(id) < height).toList();
    final candidates = near.isEmpty ? ids : near;
    b.select(candidates);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectionOwner = widget.controller.store.ownerId;
    _copyHintStore = widget.copyHintStore ?? createCopyHintStore();
    _copyHintStore
        .copiedBefore()
        .then((seen) {
          if (mounted && !_copiedThisRun) setState(() => _copyHint = !seen);
        })
        .catchError((Object _) {
          /* Preference unavailable: no repeated hint. */
        });
    widget.controller.addListener(changed);
    _batchScroll.addListener(queueBatchSelection);
    final policy = widget.batchPolicy, bridge = widget.controller.bridge;
    if (policy != null && bridge is TotpBatchBridge) {
      batch = MainPageBatchController(
        bridge: bridge as TotpBatchBridge,
        policy: policy,
        wallMilliseconds: widget.batchClock == null
            ? null
            : () => 1000000 + widget.batchClock!(),
        monotonicMilliseconds: widget.batchClock,
        active: () =>
            widget.controller.signedIn &&
            !widget.controller.suspended &&
            !widget.controller.store.sessionExpired(widget.clock()),
      )..addListener(changed);
      queueBatchSelection();
    }
    // Lets the highlight fade on its own without any refresh.
    freshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      queueBatchSelection();
      batch?.tick();
      if (mounted && (hadFresh || batch != null)) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant ProductShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.navigation != oldWidget.navigation) {
      scheduledUnavailableRoute = null;
      if (widget.navigation == 'codes') detailOwner = null;
    }
    if (selectionOwner != widget.controller.store.ownerId) {
      selectionOwner = widget.controller.store.ownerId;
      selectedAccounts.clear();
      filters.clear();
      localLastUsed.clear();
    }
  }

  void changed() {
    if (selectionOwner != widget.controller.store.ownerId) {
      selectionOwner = widget.controller.store.ownerId;
      selectedAccounts.clear();
      filters.clear();
      localLastUsed.clear();
    }
    scheduleBoundaryRepaint();
    queueBatchSelection();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    freshTimer?.cancel();
    _copiedTimer?.cancel();
    _boundaryTimer?.cancel();
    _batchScroll.dispose();
    batch?.removeListener(changed);
    batch?.dispose();
    widget.controller.removeListener(changed);
    searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> refresh() => widget.controller.refresh();

  /// Mobile-web pull reloads the document. Native hosts have no pageReload
  /// callback and never install the pull wrapper.
  Future<void> pull() async {
    await widget.pageReload?.call();
  }

  String spaced(String c) => c.length == 6
      ? '${c.substring(0, 3)} ${c.substring(3)}'
      : c.length == 8
      ? '${c.substring(0, 4)} ${c.substring(4)}'
      : c;

  Widget avatar(String name, [String? serviceId, String? issuer]) =>
      ServiceAvatar(
        service: name,
        serviceId: serviceId,
        issuer: issuer,
        color: context.pal.avatarFor(name),
        ink: context.pal.avatarInk,
      );

  Widget codeSlot(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 160),
    child: FittedBox(fit: BoxFit.scaleDown, child: child),
  );

  Widget codeTile(
    String title,
    String sub,
    String? code, [
    Future<bool> Function()? onCopy,
    bool showCodeStatus = true,
    bool fresh = false,
    Widget? trailing,
    String? serviceId,
    String? issuer,
    int? remainingMs,
    int? periodMs,
    Object? barId,
    bool renewing = false,
    String? copyId,
    bool expired = false,
    bool early = false,
    int? expectedDigits,
    Widget? below,
    Widget? leading,
    bool pin = false,
    VoidCallback? onHold,
    VoidCallback? onSelect,
    bool selected = false,
  ]) => Card(
    clipBehavior: Clip.antiAlias,
    key: fresh ? Key('fresh-$title-${code ?? ''}') : null,
    color: selected ? context.pal.fresh : (fresh ? context.pal.fresh : null),
    shape: fresh || selected
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.pal.accent, width: 1.2),
          )
        : null,
    child: InkWell(
      onLongPress: onHold,
      onTap:
          onSelect ??
          (code != null && onCopy != null && copyId != null
              ? () => copyTile(copyId, onCopy)
              : null),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  height: 40 * MediaQuery.textScalerOf(context).scale(14) / 14,
                  child: Row(
                    children: [
                      ?leading,
                      avatar(title, serviceId, issuer),
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
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.pal.muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (pin)
                        Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.push_pin,
                            size: 14,
                            color: context.pal.accent,
                          ),
                        ),
                      if (code != null) ...[
                        const SizedBox(width: 6),
                        codeSlot(
                          Stack(
                            clipBehavior: Clip.none,
                            alignment: Alignment.center,
                            children: [
                              Opacity(
                                opacity: _copiedTile == copyId && copyId != null
                                    ? 0
                                    : (expired ? 0.45 : 1),
                                child: Text(
                                  spaced(code),
                                  style: TextStyle(
                                    fontFamily: 'CodeMono',
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                    color: expired
                                        ? context.pal.muted
                                        : context.pal.ink,
                                  ),
                                ),
                              ),
                              if (expired)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: -10,
                                  child: Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Text(
                                      'Updating',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: context.pal.muted,
                                      ),
                                    ),
                                  ),
                                ),
                              if (_copiedTile == copyId && copyId != null)
                                Semantics(
                                  liveRegion: true,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.check,
                                        size: 16,
                                        color: context.pal.accent,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'Copied',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: context.pal.accent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ] else if (showCodeStatus) ...[
                        const SizedBox(width: 12),
                        SizedBox(
                          height: 48,
                          child: Center(
                            child: codeSlot(
                              Text(
                                '-' * (expectedDigits ?? 6),
                                semanticsLabel: renewing
                                    ? 'Updating code'
                                    : 'No active code',
                                style: TextStyle(
                                  fontFamily: 'CodeMono',
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                  color: context.pal.muted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (_showCopyButton &&
                          code != null &&
                          onCopy != null &&
                          copyId != null) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          key: ValueKey('copy-button-$copyId'),
                          tooltip: early
                              ? 'Copy next code to clipboard'
                              : 'Copy code to clipboard',
                          onPressed: () => copyTile(copyId, onCopy),
                          icon: const Icon(Icons.copy_outlined, size: 20),
                        ),
                      ],
                      if (trailing != null) ...[
                        const SizedBox(width: 4),
                        trailing,
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          ?below,
          if (remainingMs != null && periodMs != null && code != null)
            RefreshBar(
              key: ValueKey(barId ?? 'refresh-$title'),
              remainingMs: remainingMs,
              periodMs: periodMs,
            ),
        ],
      ),
    ),
  );

  Future<void> ruleFromReview(UnassignedContext review) async {
    final b = widget.controller.bridge;
    if (b is! RuleBridge ||
        !widget.controller.signedIn ||
        !review.retained(widget.clock())) {
      return;
    }
    final owned = widget.controller.store.entries
        .where((e) => e.manage)
        .toList();
    final entry = await showDialog<ManagedEntry>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Choose an owned account'),
        children: [
          for (final e in owned)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e),
              child: Text(
                '${e.service}${e.account.isEmpty ? '' : ' · ${e.account}'}',
              ),
            ),
        ],
      ),
    );
    if (entry == null || !mounted || !review.retained(widget.clock())) return;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => RuleActionDialog(
        bridge: b as RuleBridge,
        target: {
          'operation': 'review',
          'contextId': review.contextId,
          'entryId': entry.id,
        },
      ),
    );
    if (mounted) widget.controller.refreshAfterMutation();
  }

  void contextDetails(UnassignedContext review) =>
      openDetails(unassignedDetailRoute(review.sourceId, review.eventId));

  Widget reviewTile(
    UnassignedContext review,
    List<UnassignedCode> codes,
    int now, {
    bool arrival = false,
  }) {
    UnassignedCode? live;
    for (final code in codes) {
      if (code.sourceId == review.sourceId &&
          code.eventId == review.eventId &&
          code.active(now)) {
        live = code;
      }
    }
    final code = live;
    return codeTile(
      review.sender,
      review.sourceLabel,
      code?.value,
      code == null
          ? null
          : () async {
              if (!widget.controller.canCopyPrivate(code)) return false;
              await widget.onCopyPrivate(code);
              return true;
            },
      true,
      arrival,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Details',
            onPressed: () => contextDetails(review),
            icon: const Icon(Icons.info_outline),
          ),
          if (code != null &&
              widget.assignmentEnabled &&
              widget.controller.bridge is AssignmentBridge)
            IconButton(
              key: Key('assign-${code.eventId}'),
              tooltip: 'Assign to an entry',
              onPressed: () => assign(code),
              icon: const Icon(Icons.drive_file_move_outline),
            ),
        ],
      ),
      null,
      null,
      null,
      null,
      null,
      false,
      code == null ? null : 'private/${code.sourceId}/${code.eventId}',
    );
  }

  Widget unifiedCodes(
    List<ManagedEntry> input,
    Map<String, ReceivedCode> codes,
    int now,
  ) {
    final org = widget.organization;
    bool known(String id) {
      try {
        org?.preferencesFor(id);
        return org != null;
      } catch (_) {
        return false;
      }
    }

    bool pinned(String id) => known(id) && org!.preferencesFor(id).pinned;
    Set<String> tags(String id) =>
        known(id) ? org!.preferencesFor(id).tagIds : {};
    bool matches(ManagedEntry e) {
      final ownership = filters.intersection({'mine', 'shared'});
      final selectedTags = filters
          .where((v) => v.startsWith('tag/'))
          .map((v) => v.substring(4))
          .toSet();
      return (ownership.isEmpty ||
              ownership.contains(e.manage ? 'mine' : 'shared')) &&
          (selectedTags.isEmpty ||
              tags(e.id).intersection(selectedTags).isNotEmpty);
    }

    final entries = input.where(matches).toList();
    final byId = {for (final e in entries) e.id: e};
    final ordered = sortAccounts(
      entries.map(
        (e) => AccountSortValues(
          id: e.id,
          name: e.service,
          pinned: pinned(e.id),
          score: org?.scoreFor(e.id) ?? 0,
          createdAt: e.createdAt,
          lastUsedAt: localLastUsed[e.id] ?? org?.lastUsedDayFor(e.id),
        ),
      ),
      accountSort,
    ).map((id) => byId[id]!).toList();
    final private = widget.controller.store.visibleUnassigned(now);
    final fresh =
        entries
            .where(
              (e) =>
                  codes[e.id] != null &&
                  now - codes[e.id]!.receivedAt < freshForMs,
            )
            .toList()
          ..sort(
            (a, b) =>
                codes[b.id]!.receivedAt.compareTo(codes[a.id]!.receivedAt),
          );
    final freshPrivate =
        private
            .where(
              (c) =>
                  now - c.receivedAt < freshForMs &&
                  query.trim().isEmpty &&
                  filters.isEmpty,
            )
            .toList()
          ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    hadFresh = fresh.isNotEmpty || freshPrivate.isNotEmpty;
    final desktop = _showCopyButton;
    Widget section(String title, List<Widget> cards) => cards.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: context.pal.muted,
                    ),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, box) {
                    final count = box.maxWidth >= 1050
                        ? 3
                        : box.maxWidth >= 680
                        ? 2
                        : 1;
                    final width = (box.maxWidth - (count - 1) * 10) / count;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final card in cards)
                          SizedBox(width: width, child: card),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
    Widget account(ManagedEntry e, {bool arrival = false}) {
      final received = !e.totp || arrival ? codes[e.id] : null,
          generated = e.totp && !arrival ? batch?.tileCurrent(e.id) : null;
      final value = received?.value ?? generated?.value;
      final copyId = received != null
          ? 'entry/${e.id}/${received.receivedAt}'
          : generated != null
          ? 'totp/${e.id}/${generated.periodStartMs}'
          : null;
      Future<bool> copy() async {
        if (e.totp && !arrival) return await batch?.copy(e.id) ?? false;
        if (received == null || !widget.controller.canCopyAssigned(received)) {
          return false;
        }
        await widget.onCopyAssigned(received);
        return true;
      }

      final labels = [
        for (final t in org?.tags ?? <PersonalTag>[])
          if (tags(e.id).contains(t.id)) t.label,
      ];
      final tagRow = widget.showTileTags && !arrival
          ? Container(
              height: 34,
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: context.pal.line)),
              ),
              child: TextButton(
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: known(e.id) && !widget.organizationBusy
                    ? () => editAccountTags({e.id})
                    : null,
                child: Row(
                  children: [
                    Icon(
                      labels.isEmpty ? Icons.add : Icons.sell_outlined,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        labels.isEmpty ? 'Add tags' : labels.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null;
      final selection = desktop
          ? Checkbox(
              value: selectedAccounts.contains(e.id),
              onChanged: (_) => setState(
                () => selectedAccounts.contains(e.id)
                    ? selectedAccounts.remove(e.id)
                    : selectedAccounts.add(e.id),
              ),
            )
          : null;
      final tile = codeTile(
        e.service,
        e.account,
        value,
        generated != null && !generated.copyable ? null : copy,
        true,
        arrival,
        null,
        e.catalogId,
        e.issuer,
        generated?.remainingMs,
        generated == null ? null : generated.period * 1000,
        generated == null ? null : '${e.id}/${generated.periodStartMs}',
        e.totp && !arrival && (batch?.awaitingBoundary(e.id) ?? false),
        copyId,
        generated != null && !generated.copyable,
        generated?.early ?? false,
        batch?.expectedDigits(e.id) ?? e.expectedDigits,
        tagRow,
        selection,
        pinned(e.id),
        () => setState(
          () => selectedAccounts.contains(e.id)
              ? selectedAccounts.remove(e.id)
              : selectedAccounts.add(e.id),
        ),
        selectedAccounts.isNotEmpty
            ? () => setState(
                () => selectedAccounts.contains(e.id)
                    ? selectedAccounts.remove(e.id)
                    : selectedAccounts.add(e.id),
              )
            : null,
        selectedAccounts.contains(e.id),
      );
      return tile;
    }

    Widget unassigned(UnassignedCode c, {bool arrival = false}) => codeTile(
      'Unassigned code',
      'Only you',
      c.value,
      () async {
        if (!widget.controller.canCopyPrivate(c)) return false;
        await widget.onCopyPrivate(c);
        return true;
      },
      true,
      arrival,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Details',
            onPressed: () =>
                openDetails(unassignedDetailRoute(c.sourceId, c.eventId)),
            icon: const Icon(Icons.info_outline),
          ),
          if (widget.assignmentEnabled &&
              widget.controller.bridge is AssignmentBridge)
            IconButton(
              key: Key('assign-${c.eventId}'),
              tooltip: 'Assign to an entry',
              onPressed: () => assign(c),
              icon: const Icon(Icons.drive_file_move_outline),
            ),
        ],
      ),
      null,
      null,
      null,
      null,
      null,
      false,
      'private/${c.sourceId}/${c.eventId}',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selectedAccounts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Clear selection',
                      onPressed: () => setState(() => selectedAccounts.clear()),
                      icon: const Icon(Icons.close),
                    ),
                    Text('${selectedAccounts.length} selected'),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 40),
                          ),
                          label: Text(
                            selectedAccounts.every(pinned) ? 'Unpin' : 'Pin',
                          ),
                          onPressed: org != null && !widget.organizationBusy
                              ? () {
                                  final value = !selectedAccounts.every(pinned);
                                  for (final id in selectedAccounts.where(
                                    known,
                                  )) {
                                    org.setPinned(id, value);
                                  }
                                  widget.onOrganizationChanged?.call();
                                  setState(() {});
                                }
                              : null,
                          icon: Icon(
                            selectedAccounts.every(pinned)
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 40),
                          ),
                          label: const Text('Tags'),
                          onPressed: org != null && !widget.organizationBusy
                              ? () => editAccountTags(
                                  selectedAccounts.where(known).toSet(),
                                )
                              : null,
                          icon: const Icon(Icons.sell_outlined),
                        ),
                      ),
                    ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 40),
                          ),
                          label: const Text('Share'),
                          onPressed: null,
                          icon: Icon(
                            Icons.share_outlined,
                            color: context.pal.muted.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 40),
                          ),
                          key: selectedAccounts.length == 1
                              ? Key('edit-${selectedAccounts.single}')
                              : null,
                          label: const Text('Details'),
                          onPressed:
                              selectedAccounts.length == 1 &&
                                  input.any(
                                    (e) => selectedAccounts.contains(e.id),
                                  )
                              ? () => editEntry(
                                  input.firstWhere(
                                    (e) => selectedAccounts.contains(e.id),
                                  ),
                                )
                              : null,
                          icon: const Icon(Icons.info_outline),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        section('New arrivals', [
          for (final e in fresh) account(e, arrival: true),
          for (final c in freshPrivate)
            widget.controller.contexts.any(
                  (r) =>
                      r.sourceId == c.sourceId &&
                      r.eventId == c.eventId &&
                      r.retained(now),
                )
                ? reviewTile(
                    widget.controller.contexts.firstWhere(
                      (r) =>
                          r.sourceId == c.sourceId &&
                          r.eventId == c.eventId &&
                          r.retained(now),
                    ),
                    private,
                    now,
                    arrival: true,
                  )
                : unassigned(c, arrival: true),
        ]),
        section('Authenticator accounts', [
          for (final e in ordered.where((e) => e.totp))
            KeyedSubtree(
              key: _batchKeys.putIfAbsent(e.id, () => GlobalKey()),
              child: account(e),
            ),
        ]),
        section('Accounts', [
          for (final e in ordered.where(
            (e) => !e.totp && !fresh.any((f) => f.id == e.id),
          ))
            account(e),
        ]),
        if (filters.isEmpty && query.trim().isEmpty)
          section('Needs assignment', [
            for (final review in widget.controller.contexts.where(
              (r) =>
                  r.retained(now) &&
                  !freshPrivate.any(
                    (c) => c.sourceId == r.sourceId && c.eventId == r.eventId,
                  ),
            ))
              reviewTile(review, private, now),
            for (final c in private.where(
              (c) =>
                  !freshPrivate.contains(c) &&
                  !widget.controller.contexts.any(
                    (r) =>
                        r.sourceId == c.sourceId &&
                        r.eventId == c.eventId &&
                        r.retained(now),
                  ),
            ))
              unassigned(c),
          ]),

        if (entries.isEmpty &&
            filters.isNotEmpty &&
            (input.isNotEmpty ||
                private.isNotEmpty ||
                widget.controller.contexts.isNotEmpty))
          empty(
            'No codes match your filters',
            'Your filters are hiding the codes. Change or clear the filters to see them.',
            action: TextButton(
              onPressed: () => setState(() => filters = {}),
              child: const Text('Clear all filters'),
            ),
          )
        else if (entries.isEmpty &&
            private.isEmpty &&
            widget.controller.contexts.isEmpty)
          empty('No codes yet', 'Add an authenticator or connect a source.'),
      ],
    );
  }

  Future<void> editAccountTags(
    Set<String> ids, {
    OrganizationStore? staged,
  }) async {
    final org = staged ?? widget.organization;
    if (org == null || ids.isEmpty) return;
    final owner = widget.controller.store.ownerId;
    bool current() =>
        mounted &&
        (staged != null || identical(widget.organization, org)) &&
        widget.controller.store.ownerId == owner;
    final originalDocument = org.document();
    final draft = OrganizationStore()
      ..restore(
        {'revision': org.revision, ...org.document(), 'ranking': <Object>[]},
        (org.document()['entries'] as List).map((e) => e['entryId'] as String),
      );
    final decisions = <String, bool>{};
    var newTag = '';
    var tagInputRevision = 0;
    String? tagError;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 430),
          title: const Text('Tags for selected accounts'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('new-tag-$tagInputRevision'),
                        decoration: InputDecoration(
                          labelText: 'New tag',
                          errorText: tagError,
                        ),
                        onChanged: (value) => update(() => newTag = value),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Create tag',
                      onPressed: newTag.trim().isEmpty
                          ? null
                          : () => update(() {
                              if (!current()) return;
                              try {
                                final id =
                                    'personal-${DateTime.now().microsecondsSinceEpoch}';
                                draft.createTag(id, newTag.trim());
                                decisions[id] = true;
                                newTag = '';
                                tagInputRevision++;
                                tagError = null;
                              } catch (_) {
                                tagError = 'Use a unique tag name';
                              }
                            }),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                for (final tag in draft.tags)
                  CheckboxListTile(
                    tristate: true,
                    title: Row(
                      children: [
                        Expanded(child: Text(tag.label)),
                        IconButton(
                          tooltip: 'Rename ${tag.label}',
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () async {
                            var name = tag.label;
                            final next = await showDialog<String>(
                              context: context,
                              builder: (c) => AlertDialog(
                                constraints: const BoxConstraints(
                                  maxWidth: 400,
                                ),
                                title: const Text('Rename tag'),
                                content: TextFormField(
                                  initialValue: name,
                                  onChanged: (v) => name = v,
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, name),
                                    child: const Text('Save'),
                                  ),
                                ],
                              ),
                            );
                            if (next != null && current()) {
                              update(() {
                                try {
                                  draft.renameTag(tag.id, next);
                                  tagError = null;
                                } catch (_) {
                                  tagError = 'Use a unique tag name';
                                }
                              });
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'Delete ${tag.label}',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (c) => AlertDialog(
                                constraints: const BoxConstraints(
                                  maxWidth: 400,
                                ),
                                title: Text('Delete ${tag.label}?'),
                                content: const Text(
                                  'This removes the tag from all accounts.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true && current()) {
                              update(() {
                                draft.deleteTag(tag.id);
                                decisions.remove(tag.id);
                              });
                            }
                          },
                        ),
                      ],
                    ),
                    value:
                        decisions[tag.id] ??
                        (ids.every(
                              (id) => org
                                  .preferencesFor(id)
                                  .tagIds
                                  .contains(tag.id),
                            )
                            ? true
                            : ids.every(
                                (id) => !org
                                    .preferencesFor(id)
                                    .tagIds
                                    .contains(tag.id),
                              )
                            ? false
                            : null),
                    onChanged: (_) => update(
                      () => decisions[tag.id] =
                          !(decisions[tag.id] ??
                              ids.every(
                                (id) => org
                                    .preferencesFor(id)
                                    .tagIds
                                    .contains(tag.id),
                              )),
                    ),
                  ),
                const Text(
                  'Mixed tags stay unchanged unless you apply or remove them for all selected accounts.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true) return;
    if (!current()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Account or tags changed. Reopen Tags and try again.',
            ),
          ),
        );
      }
      return;
    }
    final accessible = widget.controller.store.entries.map((e) => e.id).toSet();
    for (final id in ids.where(accessible.contains)) {
      final tags = {...draft.preferencesFor(id).tagIds};
      for (final choice in decisions.entries) {
        choice.value ? tags.add(choice.key) : tags.remove(choice.key);
      }
      draft.setTags(id, tags);
    }
    if (!org.applyDraft(originalDocument, draft.document())) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Tags changed while this dialog was open. Reopen and try again.',
            ),
          ),
        );
      }
      return;
    }
    if (staged == null) widget.onOrganizationChanged?.call();
    setState(() {});
  }

  Widget empty(String title, String body, {Widget? action}) => Card(
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
          if (action != null) ...[const SizedBox(height: 10), action],
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
    return unifiedCodes(entries, codes, now);
  }

  /// Pick one owned entry, then hand the irreversible confirmation (with its
  /// passkey step) to [AssignmentDialog]. Nothing is assigned before that.
  Future<void> assign(UnassignedCode code) async {
    final raw = widget.controller.bridge;
    if (!widget.assignmentEnabled || raw is! AssignmentBridge) return;
    final AssignmentBridge bridge = raw as AssignmentBridge;
    final store = widget.controller.store;
    final owner = store.ownerId;
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
        closeDetails();
      }
      return;
    }
    final owned = store.entries.where((e) => e.manage).toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        constraints: const BoxConstraints(maxWidth: 400),
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
        widget.controller.store.ownerId != owner ||
        !code.active(widget.clock()) ||
        !widget.controller.store
            .visibleUnassigned(widget.clock())
            .contains(code) ||
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
    if (done == true && mounted && widget.controller.store.ownerId == owner) {
      closeDetails();
    }
  }

  bool editable(ManagedEntry e) =>
      widget.entryEditEnabled &&
      e.manage &&
      widget.controller.bridge is EntryManagementBridge;

  void editEntry(ManagedEntry e) => openDetails(accountDetailRoute(e.id));

  Widget? routedDetails() {
    final route = widget.navigation ?? localDetailRoute;
    final detail = parseDetailRoute(route);
    if (detail == null || phase != _Phase.loaded) return null;
    final owner = widget.controller.store.ownerId;
    detailOwner ??= owner;
    bool current() =>
        mounted &&
        widget.controller.signedIn &&
        widget.controller.store.ownerId == owner &&
        detailOwner == owner;
    void unavailable() {
      if (widget.controller.loading || scheduledUnavailableRoute == route) {
        return;
      }
      scheduledUnavailableRoute = route;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || (widget.navigation ?? localDetailRoute) != route) {
          return;
        }
        closeDetails(refresh: false);
      });
    }

    if (!current()) {
      unavailable();
      return const SizedBox.shrink();
    }
    if (detail.accountId != null) {
      final matches = widget.controller.store.entries.where(
        (e) => e.id == detail.accountId,
      );
      if (matches.isEmpty) {
        unavailable();
        return const SizedBox.shrink();
      }
      final e = matches.first;
      final org = widget.organization;
      Set<String> ids = {};
      try {
        ids = org?.preferencesFor(e.id).tagIds ?? {};
      } catch (_) {}
      return AccountDetailsPage(
        key: ValueKey('details/$owner/${e.id}'),
        entry: e,
        bridge: editable(e)
            ? widget.controller.bridge as EntryManagementBridge
            : null,
        isCurrent: current,
        organization: org,
        editTags: org == null || widget.organizationBusy
            ? null
            : (draft) => editAccountTags({e.id}, staged: draft),
        onOrganizationSaved: widget.saveOrganization,
        onClose: closeDetails,
        tags: [
          for (final t in org?.tags ?? <PersonalTag>[])
            if (ids.contains(t.id)) t.label,
        ],
        onTags: org == null || widget.organizationBusy
            ? null
            : () => editAccountTags({e.id}),
        onConfirmed: ({service, account}) {
          if (current()) {
            widget.controller.applyEntryEdit(
              e.id,
              service: service,
              account: account,
            );
          }
        },
      );
    }
    final now = widget.clock();
    final reviews = widget.controller.contexts.where(
      (r) =>
          r.sourceId == detail.sourceId &&
          r.eventId == detail.eventId &&
          r.retained(now),
    );
    final codes = widget.controller.store
        .visibleUnassigned(now)
        .where(
          (c) => c.sourceId == detail.sourceId && c.eventId == detail.eventId,
        );
    if (reviews.isEmpty && codes.isEmpty) {
      unavailable();
      return const SizedBox.shrink();
    }
    final review = reviews.isEmpty ? null : reviews.first;
    final code = codes.isEmpty ? null : codes.first;
    final sources = widget.controller.store.sources.where(
      (s) => s.id == detail.sourceId,
    );
    return Scaffold(
      key: const Key('unassigned-details'),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back to codes',
          onPressed: closeDetails,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Unassigned details'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ListTile(
                title: const Text('Source'),
                subtitle: Text(
                  review?.sourceLabel ??
                      (sources.isEmpty ? 'Not available' : sources.first.label),
                ),
              ),
              if (review != null) ...[
                ListTile(
                  title: const Text('From'),
                  subtitle: Text(review.sender),
                ),
                ListTile(
                  title: Text(review.contentLabel),
                  subtitle: Text(
                    review.redactedText ?? 'Message details unavailable.',
                  ),
                ),
                if (review.truncated) const Text('Text shortened.'),
              ],
              ListTile(
                title: const Text('Received'),
                subtitle: Text(
                  DateTime.fromMillisecondsSinceEpoch(
                    review?.receivedAt ?? code!.receivedAt,
                  ).toLocal().toString(),
                ),
              ),
              if (code != null &&
                  widget.assignmentEnabled &&
                  widget.controller.bridge is AssignmentBridge)
                FilledButton.icon(
                  key: Key('assign-${code.eventId}'),
                  onPressed: () {
                    if (current()) assign(code);
                  },
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: const Text('Assign to an account'),
                ),
              if (review != null && widget.controller.bridge is RuleBridge)
                OutlinedButton.icon(
                  key: const Key('save-review-rule'),
                  onPressed: () => ruleFromReview(review),
                  icon: const Icon(Icons.rule),
                  label: const Text('Save future matching rule'),
                ),
              if (code == null)
                const Text(
                  'This code has expired. Its redacted details are still available.',
                ),
            ],
          ),
        ),
      ),
    );
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
      key: const ValueKey('search-codes'),
      controller: searchController,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search accounts',
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
        fillColor: context.pal.field,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          borderSide: BorderSide(color: context.pal.accent, width: 1.5),
        ),
      ),
      onChanged: (v) => setState(() => query = v),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final detailPage = routedDetails();
      if (detailPage != null && size.maxWidth <= 700) return detailPage;
      final desktop = size.maxWidth > 700;
      _showCopyButton = desktop;
      queueBatchSelection();
      final list = ListView(
        controller: _batchScroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          desktop ? 0 : 12,
          desktop ? 20 : 14,
          desktop ? 0 : 12,
          30,
        ),
        children: [
          if (!desktop &&
              _copyHint &&
              phase == _Phase.loaded &&
              hasCopyableCard)
            copyTutorial(),
          if (widget.organizationMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(widget.organizationMessage),
            ),
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
          if (_canAddTotp) const SizedBox(height: 80),
        ],
      );
      final org = widget.organization;
      final tags = [...?org?.tags];
      int tagCount(String id) => widget.controller.store.entries.where((e) {
        try {
          return org!.preferencesFor(e.id).tagIds.contains(id);
        } catch (_) {
          return false;
        }
      }).length;
      tags.sort((a, b) {
        final n = tagCount(b.id).compareTo(tagCount(a.id));
        return n != 0
            ? n
            : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      final filterChoices = [
        const CodeFilterChoice('mine', 'Mine'),
        const CodeFilterChoice('shared', 'Shared'),
        for (final t in tags) CodeFilterChoice('tag/${t.id}', t.label),
      ];
      final content = RevealedFilterList(
        mobile: !desktop,
        filters: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: CodeFilterRow(
                  choices: filterChoices,
                  selected: filters,
                  onChanged: (value) => setState(() => filters = value),
                ),
              ),
              AccountSortButton(
                value: accountSort,
                onChanged: (value) => setState(() => accountSort = value),
              ),
            ],
          ),
        ),
        onRefresh: widget.pageReload == null ? null : pull,
        child: list,
      );
      final accountButton = IconButton(
        tooltip: 'Account & security',
        onPressed: widget.onOpenAccount,
        icon: widget.profileEmail == null
            ? SizedBox(
                key: ValueKey('home-profile-loading'),
                width: 32,
                height: 32,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.pal.line,
                    shape: BoxShape.circle,
                  ),
                ),
              )
            : ProfileAvatar(
                key: ValueKey(widget.profileEmail),
                email: widget.profileEmail!,
                googlePicture: widget.profilePicture,
                size: 32,
              ),
      );
      final workspacePage = Scaffold(
        floatingActionButton: _canAddTotp
            ? FloatingActionButton.extended(
                tooltip: 'Add authenticator',
                backgroundColor: context.pal.brand,
                foregroundColor: context.pal.onBrand,
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
                padding: desktop
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: context.pal.card,
                  border: Border(bottom: BorderSide(color: context.pal.line)),
                ),
                // Desktop mirrors the content grid below: the brand sits over
                // the 232-wide nav column, the search fills the content
                // column, and the account button ends at the content column's
                // right edge.
                child: desktop
                    ? Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1100),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 180,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 24),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Image.memory(
                                          bareOttyImage,
                                          width: 42,
                                          height: 42,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'OTPanda',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontFamily: 'BricolageGrotesque',
                                            fontSize: 23,
                                            letterSpacing: -1,
                                            color: context.pal.ink,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: phase == _Phase.loaded && searchable
                                    ? searchField(false)
                                    : const SizedBox.shrink(),
                              ),
                              const SizedBox(width: 8),
                              accountButton,
                              const SizedBox(width: 24),
                            ],
                          ),
                        ),
                      )
                    : Row(
                        children: [
                          Image.memory(bareOttyImage, width: 42, height: 42),
                          const SizedBox(width: 10),
                          Expanded(
                            child: phase == _Phase.loaded && searchable
                                ? searchField(true)
                                : const SizedBox.shrink(),
                          ),
                          const SizedBox(width: 6),
                          accountButton,
                        ],
                      ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: content,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      if (detailPage == null) return workspacePage;
      return Row(
        key: const Key('details-right-panel'),
        children: [
          Expanded(child: workspacePage),
          VerticalDivider(width: 1, color: context.pal.line),
          SizedBox(
            width: (size.maxWidth * 0.42).clamp(360.0, 520.0),
            child: detailPage,
          ),
        ],
      );
    },
  );
}
