import 'dart:async';
import 'dart:convert';

import 'assignment_dialog.dart';

import 'organization_contract.dart';
import 'organization_panel.dart';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'browser_session.dart';
import 'browser_session_contract.dart';
import 'session_contract.dart';

class _ReadTransport implements SessionTransport {
  final BrowserSessionBridge bridge;
  const _ReadTransport(this.bridge);
  @override
  Future<SessionResponse> getManagement(String path) => bridge.read(path);
  @override
  Future<void> close() async {}
}

/// Separate from fictional preview. Read-only data and browser signout only.
class BrowserAccountPage extends StatefulWidget {
  final BrowserSessionBridge? bridge;
  final bool loginEnabled;
  final bool assignmentEnabled;
  final bool accountOnly;
  final int Function()? clock;
  const BrowserAccountPage({
    super.key,
    this.bridge,
    this.loginEnabled = false,
    this.assignmentEnabled = false,
    this.accountOnly = false,
    this.clock,
  });
  @override
  State<BrowserAccountPage> createState() => _BrowserAccountPageState();
}

class _BrowserAccountPageState extends State<BrowserAccountPage>
    with WidgetsBindingObserver {
  late final BrowserSessionBridge bridge;
  late final CodeStore store;
  bool busy = true;
  String status = 'loading', message = '';
  int revision = 0;
  int? accountExpiresAt;
  final organization = OrganizationStore();
  bool organizationReady = false, organizationBusy = false;
  int organizationEpoch = 0, organizationSnapshot = 0, organizationRequest = 0;
  Timer? expiryTick;
  int now() => widget.clock?.call() ?? DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    bridge = widget.bridge ?? createBrowserSession();
    store = CodeStore(_ReadTransport(bridge));
    expiryTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && status == 'restored') {
        if ((widget.accountOnly &&
                accountExpiresAt != null &&
                now() >= accountExpiresAt!) ||
            store.sessionExpired(now())) {
          clearOrganization();
          store.clear();
          status = 'sign-in-required';
          message = 'Browser access expired. Sign in again.';
        }
        setState(() {});
      }
    });
    initialize();
  }

  Future<void> initialize() async {
    try {
      await bridge.ready;
      if (!mounted) return;
      setState(() => status = bridge.status);
      if (status == 'restored') await refresh();
    } catch (_) {
      message = 'Could not check this browser session.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> run(
    Future<void> Function() action, {
    bool loadAfter = true,
  }) async {
    final attempt = ++revision;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
      if (!mounted || attempt != revision) return;
      status = bridge.status;
      if (status == 'restored' && loadAfter) {
        await loadAccount(attempt);
      } else if (status == 'sign-in-required') {
        message =
            'Sign-in did not finish. Start again when sign-in is available.';
      }
    } catch (_) {
      if (!mounted || attempt != revision) return;
      clearOrganization();
      store.clear();
      status = bridge.status;
      message = 'Could not complete that request. Try again.';
    } finally {
      if (mounted && attempt == revision) setState(() => busy = false);
    }
  }

  Future<void> refresh() => run(() async {
    clearOrganization();
    await loadAccount(revision);
  }, loadAfter: false);
  Future<void> loadAccount(int attempt) async {
    if (!widget.accountOnly) {
      await store.load(now, includePrivateInbox: true);
      if (mounted && attempt == revision && bridge.status == 'restored') {
        await loadOrganization();
      }
      return;
    }
    accountExpiresAt = null;
    final response = await bridge.read('/v1/manage/session');
    if (!mounted || attempt != revision) return;
    if (response.status == 401) {
      bridge.clear();
      status = 'sign-in-required';
      return;
    }
    if (response.status != 200) throw const ClientFailure();
    final value = jsonDecode(response.body);
    if (value is! Map<String, dynamic> ||
        value.keys.length != 2 ||
        value['ownerId'] is! String ||
        (value['ownerId'] as String).isEmpty ||
        (value['ownerId'] as String).length > 256 ||
        value['expiresAt'] is! int ||
        (value['expiresAt'] as int) <= now()) {
      throw const FormatException('Invalid session metadata');
    }
    accountExpiresAt = value['expiresAt'] as int;
  }

  void clearOrganization() {
    accountExpiresAt = null;
    organizationEpoch++;
    organizationRequest++;
    organization.clear();
    organizationReady = false;
    organizationBusy = false;
  }

  Future<void> loadOrganization() async {
    final epoch = organizationEpoch;
    final request = ++organizationRequest;
    final response = await bridge.organize('GET', '');
    if (!mounted ||
        epoch != organizationEpoch ||
        request != organizationRequest) {
      return;
    }
    if (response.status == 401) {
      clearOrganization();
      store.clear();
      status = 'sign-in-required';
      return;
    }
    if (response.status != 200) {
      organizationReady = false;
      return;
    }
    try {
      organization.restore(
        jsonDecode(response.body) as Map<String, dynamic>,
        store.entries.map((e) => e.id),
      );
      organizationSnapshot++;
      organizationReady = true;
    } catch (_) {
      organizationReady = false;
    }
  }

  Future<void> saveOrganization() async {
    if (!organizationReady || organizationBusy || status != 'restored') return;
    final epoch = organizationEpoch;
    setState(() => organizationBusy = true);
    try {
      final response = await bridge.organize(
        'PUT',
        jsonEncode({
          'revision': organization.revision,
          'document': organization.document(),
        }),
      );
      if (!mounted || epoch != organizationEpoch) return;
      if (response.status != 200) message = 'Organization was not saved. Refresh to check current cloud choices.';
      await loadOrganization();
    } catch (_) {
      if (!mounted || epoch != organizationEpoch) return;
      organizationReady = false;
      message = 'Could not confirm organization changes. Refresh before editing again.';
    } finally {
      if (mounted && epoch == organizationEpoch) {
        setState(() => organizationBusy = false);
      }
    }
  }

  void clear() {
    revision++;
    bridge.clear();
    clearOrganization();
    store.clear();
    setState(() {
      busy = false;
      status = 'idle';
      message = 'Local access cleared. This does not revoke the saved browser session.';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (widget.accountOnly) {
        revision++;
        busy = false;
      }
      clearOrganization();
      store.clear();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    revision++;
    expiryTick?.cancel();
    clearOrganization();
    store.clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> assignPrivate(UnassignedCode code) async {
    if (!widget.assignmentEnabled ||
        bridge is! AssignmentBridge ||
        status != 'restored' ||
        !code.active(now())) {
      return;
    }
    final assignment = bridge as AssignmentBridge;
    if ([
      'unknown',
      'pending',
      'submitting',
    ].contains(assignment.assignmentState)) {
      final assigned = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AssignmentDialog(
          bridge: assignment,
          sourceId: '',
          eventId: '',
          entryId: '',
        ),
      );
      if (mounted && assigned == true) await refresh();
      return;
    }
    final epoch = revision;
    final owned = store.entries.where((entry) => entry.manage).toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose an owned entry'),
        children: [
          for (final entry in owned)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.id),
              child: Text(
                '${entry.service}${entry.account.isEmpty ? '' : ' · ${entry.account}'}',
              ),
            ),
        ],
      ),
    );
    if (!mounted ||
        target == null ||
        epoch != revision ||
        status != 'restored' ||
        !code.active(now()) ||
        !store.visibleUnassigned(now()).contains(code) ||
        !store.entries.any((entry) => entry.id == target && entry.manage)) {
      return;
    }
    final assigned = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AssignmentDialog(
        bridge: bridge as AssignmentBridge,
        sourceId: code.sourceId,
        eventId: code.eventId,
        entryId: target,
      ),
    );
    if (mounted && assigned == true) await refresh();
  }

  Future<void> copyPrivate(UnassignedCode code) async {
    if (status != 'restored' ||
        !code.active(now()) ||
        !store.visibleUnassigned(now()).contains(code)) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: code.value));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Code copied. Other apps may retain clipboard contents.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not copy code.')));
      }
    }
  }

  Future<void> copyAssigned(ReceivedCode code) async {
    final epoch = organizationEpoch;
    if (status != 'restored' || !store.visibleCodes(now()).contains(code)) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: code.value));
      if (mounted &&
          epoch == organizationEpoch &&
          status == 'restored' &&
          store.visibleCodes(now()).contains(code)) {
        try {
          await bridge.copied(code.entryId, now());
          if (mounted && epoch == organizationEpoch) {
            await loadOrganization();
            if (mounted && epoch == organizationEpoch) setState(() {});
          }
        } catch (_) {
          /* Clipboard success does not depend on ranking sync. */
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Code copied. Other apps may retain clipboard contents.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not copy code.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final codes = store.visibleCodes(now());
    return Scaffold(
      appBar: AppBar(title: const Text('Browser account')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Real account connection',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Text(
                !widget.loginEnabled
                    ? 'This is separate from the fictional development preview. Real authentication is not enabled in the current deployment.'
                    : widget.accountOnly
                    ? 'Account access only. Sources, real codes, sharing and account recovery are not available in this stage.'
                    : 'This is separate from the fictional development preview.',
              ),
              const SizedBox(height: 20),
              Text(
                status == 'unsupported'
                    ? 'Native sign-in is not connected yet.'
                    : status == 'signup-ready'
                    ? 'Create a passkey for your verified account email.'
                    : status == 'signup-retry-required'
                    ? 'Passkey setup did not finish. Return to the signup form in this same browser and retry using the email proof. If you already created the passkey, use ordinary sign-in.'
                    : status == 'check-clock-or-restart'
                    ? 'Check your device date and time, then restart signup or sign-in. The secure request may have expired.'
                    : status == 'passkey-ready'
                    ? 'Your browser is ready for its passkey prompt.'
                    : status == 'restored'
                    ? 'Browser session available.'
                    : 'No active browser access.',
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              if (message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(message),
                ),
              const SizedBox(height: 16),
              if (status == 'passkey-ready' || status == 'signup-ready')
                FilledButton(
                  onPressed: busy ? null : () => run(bridge.passkey),
                  child: Text(
                    status == 'signup-ready' ? 'Create passkey' : 'Use passkey',
                  ),
                ),
              if (status != 'unsupported' &&
                  status != 'restored' &&
                  status != 'passkey-ready' &&
                  status != 'signup-ready') ...[
                FilledButton(
                  onPressed: busy || !widget.loginEnabled
                      ? null
                      : () => run(() => bridge.start('login')),
                  child: const Text('Sign in with passkey'),
                ),
                OutlinedButton(
                  onPressed: busy || !widget.loginEnabled
                      ? null
                      : () => run(() => bridge.start('restore')),
                  child: const Text('Restore saved browser session'),
                ),
                OutlinedButton(
                  onPressed: busy || !widget.loginEnabled
                      ? null
                      : () => run(() => bridge.start('signup')),
                  child: const Text('Create account with a passkey'),
                ),
                const Text(
                  'After opening an email, return to the browser where signup started. Reloading this page clears a pending passkey request. Return to the same signup form to retry, or sign in if the passkey was already created.',
                ),
                if (!widget.loginEnabled)
                  const Text(
                    'Sign-in will be available after the complete flow is enabled and checked.',
                  ),
              ],
              if (status == 'restored' && widget.accountOnly) ...[
                Text(
                  accountExpiresAt == null
                      ? 'Session could not be verified. Retry the session check.'
                      : 'Account session verified. Sources and codes are unavailable in this stage.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : refresh,
                  child: const Text('Check account session'),
                ),
              ],
              if (status == 'restored' && !widget.accountOnly) ...[
                if (store.visibleUnassigned(now()).isNotEmpty) ...[
                  const Text(
                    'Fresh private unassigned codes',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'Only you can see these. No service or shared entry has been selected.',
                  ),
                  for (final code in store.visibleUnassigned(now()))
                    ListTile(
                      title: Text(code.value),
                      subtitle: Text(
                        store.sources
                            .firstWhere((s) => s.id == code.sourceId)
                            .label,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.assignmentEnabled &&
                              bridge is AssignmentBridge)
                            IconButton(
                              tooltip: 'Assign private code',
                              onPressed: () => assignPrivate(code),
                              icon: const Icon(Icons.move_to_inbox_outlined),
                            ),
                          IconButton(
                            tooltip: 'Copy private code',
                            onPressed: () => copyPrivate(code),
                            icon: const Icon(Icons.copy_outlined),
                          ),
                        ],
                      ),
                    ),
                ],
                if (codes.isNotEmpty) ...[
                  const Text(
                    'Received entry codes',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final code in codes)
                    Builder(
                      builder: (context) {
                        final entry = store.entries.firstWhere(
                          (e) => e.id == code.entryId,
                        );
                        return ListTile(
                          title: Text(code.value),
                          subtitle: Text(
                            '${entry.service}${entry.account.isEmpty ? '' : ' · ${entry.account}'}${entry.manage ? '' : '\nShared with you · Read-only · Source hidden'}',
                          ),
                          trailing: IconButton(
                            tooltip: 'Copy entry code',
                            onPressed: () => copyAssigned(code),
                            icon: const Icon(Icons.copy_outlined),
                          ),
                        );
                      },
                    ),
                ],
                FilledButton(
                  onPressed: busy ? null : refresh,
                  child: const Text('Refresh real codes'),
                ),
                if (!busy && codes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No active codes in selected entries.'),
                  ),
                if (!organizationReady)
                  for (final entry in store.entries)
                    ListTile(
                      title: Text(entry.service),
                      subtitle: Text(
                        entry.account.isEmpty
                            ? 'No account label'
                            : entry.account,
                      ),
                      trailing: Text(
                        '${codes.where((c) => c.entryId == entry.id).length} active',
                        semanticsLabel: 'Active code count',
                      ),
                    ),
              ],
              if (status != 'unsupported' && widget.loginEnabled)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton(
                    onPressed: busy
                        ? null
                        : () {
                            revision++;
                            clearOrganization();
                            store.clear();
                            try {
                              bridge.logout();
                              message = 'Confirm signout on the API page. Until then the saved browser session is not revoked.';
                            } catch (_) {
                              message = 'Could not open signout. Local access is cleared but the saved browser session is not revoked.';
                            }
                            setState(() {
                              status = bridge.status;
                              busy = false;
                            });
                          },
                    child: const Text('Sign out of this browser'),
                  ),
                ),
              if (status != 'unsupported')
                TextButton(
                  onPressed: clear,
                  child: const Text('Clear local access'),
                ),
              if (status == 'restored' && organizationReady)
                AbsorbPointer(
                  absorbing: organizationBusy,
                  child: OrganizationPanel(
                    key: ValueKey('$organizationEpoch:$organizationSnapshot'),
                    store: organization,
                    entries: [
                      for (final e in store.entries)
                        OrganizationPanelEntry(e.id, e.service, e.account),
                    ],
                    viewerEpoch: organizationSnapshot,
                    onChanged: saveOrganization,
                  ),
                ),
              if (organizationBusy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}
