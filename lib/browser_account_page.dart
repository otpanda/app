import 'auth_entry.dart';
import 'product_shell.dart';
import 'read_workspace_controller.dart';
import 'main.dart' show ClientHome;

import 'dart:async';
import 'dart:convert';

import 'assignment_dialog.dart';

import 'organization_contract.dart';
import 'organization_panel.dart';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'browser_session.dart';
import 'browser_session_contract.dart';
import 'recovery_contract.dart';
import 'recovery_panel.dart';
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
  final bool workspaceEnabled;
  final int Function()? clock;
  const BrowserAccountPage({
    super.key,
    this.bridge,
    this.loginEnabled = false,
    this.assignmentEnabled = false,
    this.accountOnly = false,
    this.workspaceEnabled = false,
    this.clock,
  });
  @override
  State<BrowserAccountPage> createState() => _BrowserAccountPageState();
}

class _BrowserAccountPageState extends State<BrowserAccountPage>
    with WidgetsBindingObserver {
  late final BrowserSessionBridge bridge;
  late final CodeStore store;
  late final ReadWorkspaceController workspace;
  bool accountOpen = false;
  bool busy = true;
  String status = 'loading', message = '';
  int revision = 0;
  int? accountExpiresAt;
  Map<String, dynamic>? overview, securityInfo;
  String? settingChange;
  bool securityOpen = false;
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
    workspace = ReadWorkspaceController(bridge: bridge, clock: now);
    workspace.addListener(workspaceChanged);
    expiryTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && status == 'authenticating' && bridge.status != status) {
        setState(() => status = bridge.status);
      }
      if (mounted && status == 'restored') {
        if (widget.workspaceEnabled) workspace.tick();
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

  void workspaceChanged() {
    if (!mounted) return;
    if (workspace.sessionEnded) {
      status = 'sign-in-required';
    } else if (!workspace.signedIn) {
      status = bridge.status;
    }
    setState(() {});
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
      if (loadAfter && bridge.status == 'restored' && workspace.sessionEnded) {
        workspace.resetSession();
      }
      status = workspace.sessionEnded ? 'sign-in-required' : bridge.status;
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
    overview = null;
    if (widget.workspaceEnabled && !accountOpen) {
      await workspace.refresh();
      if (workspace.sessionEnded) status = 'sign-in-required';
      return;
    }
    if (!mounted || attempt != revision || bridge.status != 'restored') return;
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
    final info = await bridge.read('/v1/manage/account');
    if (!mounted || attempt != revision || status != 'restored') return;
    if (info.status == 200) {
      final v = jsonDecode(info.body);
      if (v is Map<String, dynamic> &&
          v['email'] is String &&
          v['passkeys'] is int &&
          v['google'] is bool &&
          v['recoveryDevices'] is int) {
        overview = v;
      }
    }
  }

  Future<void> loadSecurity() async {
    if (bridge is! AuthEntryBridge) {
      return;
    }
    final value = jsonDecode(
      await (bridge as AuthEntryBridge).security('status'),
    );
    if (value is! Map<String, dynamic> ||
        value['enabled'] is! bool ||
        value['pending'] is! List ||
        value['changes'] is! List) {
      throw const FormatException('Invalid security state');
    }
    if (mounted) {
      setState(() {
        securityInfo = value;
        securityOpen = true;
      });
    }
  }

  bool get clientApprovalAvailable =>
      bridge is RecoveryBridge &&
      (bridge as RecoveryBridge).enrolledClientApprovalAvailable;

  Future<void> changeSecurity(bool enabled, bool otherClient) async {
    if (otherClient && !clientApprovalAvailable) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          enabled
              ? 'Require extra verification?'
              : 'Turn off extra verification?',
        ),
        content: Text(
          enabled
              ? 'On new devices, Google alone will no longer be enough. You will need a passkey. Losing every passkey can lock you out. Approval from another enrolled device is not available yet. Remembered devices do not need this extra step.'
              : 'Google alone will be enough on new devices again. Verify this change with your passkey.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(enabled ? 'Continue' : 'Turn off'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    await run(() async {
      final b = bridge as AuthEntryBridge;
      if (otherClient) {
        final value = jsonDecode(await b.security('request-change', enabled));
        settingChange = value['changeId'] as String;
        message = 'Open Security on your other device to approve this exact change, then check here.';
      } else {
        await b.security('toggle', enabled);
      }
      await loadSecurity();
    });
  }

  void clearOrganization() {
    accountExpiresAt = null;
    overview = null;
    securityInfo = null;
    settingChange = null;
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
    workspace.clear();
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
    if (state == AppLifecycleState.resumed) {
      if (widget.workspaceEnabled) workspace.resume();
    } else {
      if (widget.workspaceEnabled) workspace.suspend();
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
    workspace.removeListener(workspaceChanged);
    workspace.dispose();
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
    if (widget.workspaceEnabled && status == 'restored' && !accountOpen) {
      return ProductShell(
        controller: workspace,
        clock: now,
        onSignedOut: () {
          bridge.clear();
          setState(() => status = bridge.status);
        },
        onOpenAccount: () {
          workspace.suspend();
          setState(() => accountOpen = true);
          refresh();
        },
        onCopyAssigned: workspace.copyAssigned,
        onCopyPrivate: workspace.copyPrivate,
      );
    }

    if (widget.accountOnly && status != 'restored') {
      return Scaffold(
        appBar: AppBar(
          title: const Text('OTPanda'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ClientHome(fictionalCatalog: true),
                ),
              ),
              child: const Text('Temporary demo'),
            ),
          ],
        ),
        body: AuthEntry(
          bridge: bridge,
          status: status,
          message: message,
          busy: busy,
          run: (action) => run(action),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        leading: widget.workspaceEnabled
            ? IconButton(
                tooltip: 'Back to codes',
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  workspace.resume();
                  setState(() => accountOpen = false);
                  workspace.refresh();
                },
              )
            : null,
        title: const Text('Your account'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ClientHome(fictionalCatalog: true),
              ),
            ),
            child: const Text('Temporary demo'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Your account',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              const Text('Your sign-in methods and security, in one place.'),
              const SizedBox(height: 20),
              if (status != 'restored')
                Text(
                  status == 'unsupported'
                      ? 'Use a browser to sign in on this device.'
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
              ],
              if (status == 'restored' && widget.accountOnly) ...[
                if (overview != null) ...[
                  if (overview!['google'] == true &&
                      overview!['passkeys'] == 0) ...[
                    const Text(
                      'Welcome to OTPanda.',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Your account is ready. Google will keep working as your sign-in. You can also add a passkey now or later.',
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    overview!['email'] as String,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Sign-in methods',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  if (overview!['google'] == true)
                    const ListTile(
                      leading: Icon(Icons.account_circle_outlined),
                      title: Text('Google'),
                      subtitle: Text('Connected'),
                    ),
                  ListTile(
                    leading: const Icon(Icons.key_outlined),
                    title: const Text('Passkeys'),
                    subtitle: Text('${overview!['passkeys']} registered'),
                  ),
                  if ((overview!['passkeys'] as int) > 0 &&
                      bridge is AdditionalPasskeyBridge)
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await (bridge as AdditionalPasskeyBridge)
                                  .addPasskey();
                              await loadAccount(revision);
                            }),
                      child: const Text('Add another passkey'),
                    ),
                  if (overview!['passkeys'] == 0 &&
                      bridge is FirstPasskeyBridge &&
                      (bridge as FirstPasskeyBridge).firstPasskeyAvailable)
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await (bridge as FirstPasskeyBridge)
                                  .firstPasskey();
                              await loadAccount(revision);
                            }),
                      child: const Text('Add a passkey'),
                    ),
                  if (overview!['passkeys'] == 0 &&
                      overview!['google'] == true &&
                      (bridge is! FirstPasskeyBridge ||
                          !(bridge as FirstPasskeyBridge)
                              .firstPasskeyAvailable))
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() => bridge.start('google')),
                      child: const Text(
                        'Sign in with Google again to add a passkey',
                      ),
                    ),
                  if (overview!['passkeys'] == 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Add a passkey as another way in. Your Google sign-in will keep working.',
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                if (bridge is AuthEntryBridge) ...[
                  const Divider(height: 32),
                  TextButton(
                    onPressed: busy ? null : () => run(loadSecurity),
                    child: const Text('Security'),
                  ),
                  if (securityOpen && securityInfo != null) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Extra verification on new devices'),
                      subtitle: Text(
                        securityInfo!['enabled'] == true
                            ? 'New devices need a passkey. Approval from another enrolled device is not available yet.'
                            : 'Google sign-in alone is enough. Turn this on for another check on new devices.',
                      ),
                      value: securityInfo!['enabled'] as bool,
                      onChanged: busy
                          ? null
                          : (enabled) => changeSecurity(enabled, false),
                    ),
                    if (clientApprovalAvailable)
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => changeSecurity(
                                !(securityInfo!['enabled'] as bool),
                                true,
                              ),
                        child: const Text(
                          'Verify change with another signed-in device',
                        ),
                      ),
                    if (clientApprovalAvailable && settingChange != null)
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await (bridge as AuthEntryBridge).security(
                                  'consume-change',
                                  false,
                                  settingChange!,
                                );
                                settingChange = null;
                                await loadSecurity();
                              }),
                        child: const Text('Check approval for security change'),
                      ),
                    for (final raw in securityInfo!['pending'] as List)
                      if (raw is Map && raw['pendingId'] is String)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('New-device sign-in request'),
                                Text(
                                  'Match code: ${(raw['pendingId'] as String).substring(0, (raw['pendingId'] as String).length < 6 ? (raw['pendingId'] as String).length : 6).toUpperCase()}',
                                ),
                                Text(
                                  'Requested at ${DateTime.fromMillisecondsSinceEpoch(raw['createdAt'] as int).toLocal()}',
                                ),
                                const Text(
                                  'Approve with a passkey on the device where you started this sign-in. Approval here from an enrolled device is not available yet.',
                                ),
                                Wrap(
                                  spacing: 12,
                                  children: [
                                    if (clientApprovalAvailable)
                                      TextButton(
                                        onPressed: busy
                                            ? null
                                            : () => run(() async {
                                                await (bridge
                                                        as AuthEntryBridge)
                                                    .security(
                                                      'approve',
                                                      false,
                                                      raw['pendingId']
                                                          as String,
                                                    );
                                                await loadSecurity();
                                              }),
                                        child: const Text('Approve sign-in'),
                                      ),
                                    TextButton(
                                      onPressed: busy
                                          ? null
                                          : () => run(() async {
                                              await (bridge as AuthEntryBridge)
                                                  .security(
                                                    'deny',
                                                    false,
                                                    raw['pendingId'] as String,
                                                  );
                                              await loadSecurity();
                                            }),
                                      child: const Text('Deny'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    if (clientApprovalAvailable)
                      for (final raw in securityInfo!['changes'] as List)
                        if (raw is Map && raw['changeId'] is String)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    raw['enabled'] == true
                                        ? 'Turn extra verification ON?'
                                        : 'Turn extra verification OFF?',
                                  ),
                                  const Text(
                                    'Approve only if you requested this exact change on your other device.',
                                  ),
                                  TextButton(
                                    onPressed: busy
                                        ? null
                                        : () => run(() async {
                                            await (bridge as AuthEntryBridge)
                                                .security(
                                                  'approve-change',
                                                  false,
                                                  raw['changeId'] as String,
                                                );
                                            await loadSecurity();
                                          }),
                                    child: const Text(
                                      'Approve security change',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                    TextButton(
                      onPressed: busy ? null : () => run(loadSecurity),
                      child: const Text('Check for sign-in requests'),
                    ),
                  ],
                ],
                if (bridge case final RecoveryBridge r
                    when r.recoveryAvailable) ...[
                  const Divider(height: 32),
                  RecoveryPanel(bridge: r),
                  const SizedBox(height: 16),
                ],
                ExpansionTile(
                  title: const Text('Temporary diagnostics'),
                  subtitle: const Text('Development controls, to be removed'),
                  children: [
                    Text(
                      accountExpiresAt == null
                          ? 'Session check unavailable.'
                          : 'Account session verified.',
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : refresh,
                      child: const Text('Check account session'),
                    ),
                    TextButton(
                      onPressed: clear,
                      child: const Text('Clear local access'),
                    ),
                  ],
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
                            workspace.clear();
                            store.clear();
                            try {
                              bridge.logout();
                              message = 'Signing out...';
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
              if (status != 'unsupported' && !widget.accountOnly)
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
