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

/// Separate from fictional preview. No mutation or native-auth claim.
class BrowserAccountPage extends StatefulWidget {
  final BrowserSessionBridge? bridge;
  final bool loginEnabled;
  const BrowserAccountPage({super.key, this.bridge, this.loginEnabled = false});
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    bridge = widget.bridge ?? createBrowserSession();
    store = CodeStore(_ReadTransport(bridge));
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
        await store.load(() => DateTime.now().millisecondsSinceEpoch);
      } else if (status == 'sign-in-required') {
        message =
            'Sign-in did not finish. Start again when sign-in is available.';
      }
    } catch (_) {
      if (!mounted || attempt != revision) return;
      store.clear();
      status = bridge.status;
      message = 'Could not complete that request. Try again.';
    } finally {
      if (mounted && attempt == revision) setState(() => busy = false);
    }
  }

  Future<void> refresh() => run(
    () => store.load(() => DateTime.now().millisecondsSinceEpoch),
    loadAfter: false,
  );
  void clear() {
    revision++;
    bridge.clear();
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
      store.clear();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    revision++;
    store.clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final codes = store.visibleCodes(DateTime.now().millisecondsSinceEpoch);
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
              const Text(
                'This is separate from the fictional development preview. Real authentication is not enabled in the current deployment.',
              ),
              const SizedBox(height: 20),
              Text(
                status == 'unsupported'
                    ? 'Native sign-in is not connected yet.'
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
              if (status == 'passkey-ready')
                FilledButton(
                  onPressed: busy ? null : () => run(bridge.passkey),
                  child: const Text('Use passkey'),
                ),
              if (status != 'unsupported' &&
                  status != 'restored' &&
                  status != 'passkey-ready') ...[
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
                if (!widget.loginEnabled)
                  const Text(
                    'Sign-in will be available after the complete flow is enabled and checked.',
                  ),
              ],
              if (status == 'restored') ...[
                FilledButton(
                  onPressed: busy ? null : refresh,
                  child: const Text('Refresh real codes'),
                ),
                if (!busy && codes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No active real codes.'),
                  ),
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
              if (status != 'unsupported')
                TextButton(
                  onPressed: clear,
                  child: const Text('Clear local access'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
