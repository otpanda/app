import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'otpauth.dart';
import 'qr_scanner.dart';
import 'session_contract.dart';
import 'totp_read_contract.dart';

class _TotpTransport implements SessionTransport {
  final BrowserSessionBridge bridge;
  final String entry;
  const _TotpTransport(this.bridge, this.entry);
  @override
  Future<SessionResponse> getManagement(String path) =>
      path == '/v1/manage/session'
      ? bridge.read(path)
      : (bridge as TotpManagementBridge).totpCode(entry);
  @override
  Future<void> close() async {}
}

class TotpEntryDialog extends StatefulWidget {
  final BrowserSessionBridge bridge;
  final String entryId;
  const TotpEntryDialog({
    super.key,
    required this.bridge,
    required this.entryId,
  });
  @override
  State<TotpEntryDialog> createState() => _TotpEntryDialogState();
}

class _TotpEntryDialogState extends State<TotpEntryDialog>
    with WidgetsBindingObserver {
  bool paused = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    paused =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (paused) {
      store.clear();
    } else if (state == AppLifecycleState.resumed) {
      retryAt = 0;
      load();
    }
    if (mounted) setState(() {});
  }

  final watch = Stopwatch()..start();
  late final store = TotpReadStore(
    _TotpTransport(widget.bridge, widget.entryId),
    monotonicMilliseconds: () => watch.elapsedMilliseconds,
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    store.clear();
    watch.stop();
    super.dispose();
  }

  Timer? timer;
  bool loading = false;
  int retryAt = 0;
  String error = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || paused) return;
      if (store.remainingSeconds() == 0 &&
          DateTime.now().millisecondsSinceEpoch >= retryAt) {
        load();
      }
      setState(() {});
    });
  }

  Future<void> load() async {
    if (loading || paused) return;
    loading = true;
    try {
      await store.load(widget.entryId);
      error = '';
    } catch (_) {
      error = 'Waiting for your connection. Retrying automatically.';
    } finally {
      retryAt = DateTime.now().millisecondsSinceEpoch + 5000;
      loading = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = store.visible(), left = store.remainingSeconds();
    return AlertDialog(
      title: const Text('Authenticator code'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              code?.value ?? '------',
              style: const TextStyle(
                fontSize: 36,
                fontFamily: 'Figtree',
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              code == null
                  ? 'Checking automatically...'
                  : 'Expires in $left seconds',
            ),
            if (error.isNotEmpty) Text(error),
            IconButton(
              tooltip: 'Copy code',
              onPressed: code == null
                  ? null
                  : () async {
                      final current = store.visible();
                      if (current != null) {
                        await Clipboard.setData(
                          ClipboardData(text: current.value),
                        );
                      }
                    },
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

Future<bool> totpPrerequisite(
  BuildContext context,
  BrowserSessionBridge bridge,
  VoidCallback? openAccount,
) async {
  try {
    final response = await bridge.read('/v1/manage/account');
    final data = jsonDecode(response.body);
    if (response.status != 200 || data is! Map || data['passkeys'] is! int) {
      throw const ClientFailure();
    }
    if (data['passkeys'] > 0) return true;
    if (!context.mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a passkey first'),
        content: const Text(
          'A passkey is needed to verify authenticator setup. Add one in Account & security, then return here. Your existing sign-in keeps working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Account & security'),
          ),
        ],
      ),
    );
    if (go == true) openAccount?.call();
  } catch (_) {
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not check passkeys'),
          content: const Text(
            'Check your connection and try adding the authenticator again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
  }
  return false;
}

Future<String?> addTotpDialog(
  BuildContext context,
  TotpManagementBridge bridge, {
  OtpauthScan scan = scanOtpauth,
}) async => showDialog<String>(
  context: context,
  builder: (_) => _AddTotp(bridge: bridge, scan: scan),
);

class _AddTotp extends StatefulWidget {
  final TotpManagementBridge bridge;
  final OtpauthScan scan;
  const _AddTotp({required this.bridge, required this.scan});
  @override
  State<_AddTotp> createState() => _AddTotpState();
}

class _AddTotpState extends State<_AddTotp> {
  final label = TextEditingController(),
      account = TextEditingController(),
      secret = TextEditingController();
  bool busy = false;
  String error = '';
  @override
  void dispose() {
    secret.clear();
    label.dispose();
    account.dispose();
    secret.dispose();
    super.dispose();
  }

  Future<void> scanQr() async {
    if (busy) return;
    OtpauthImport? found;
    try {
      found = await widget.scan(context);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Could not open the camera. Enter the setup key by hand.',
        );
      }
      return;
    }
    if (found == null || !mounted) return;
    setState(() {
      label.text = found!.name;
      account.text = found.account;
      secret.text = found.uri;
      error = '';
    });
  }

  Future<void> save() async {
    if (busy) return;
    if (label.text.trim().isEmpty || secret.text.trim().isEmpty) {
      setState(() => error = 'Enter a name and setup key.');
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final id = await widget.bridge.addTotp(
        label.text.trim(),
        account.text.trim(),
        secret.text.trim(),
      );
      secret.clear();
      if (mounted) Navigator.pop(context, id);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not add authenticator. Check the setup key and verify with an existing passkey.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add authenticator'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Scan the QR code, or enter a setup key or otpauth URI. The key is encrypted in your cloud account so OTPanda can generate codes. Verify with a passkey to save.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: busy ? null : scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
            ),
            TextField(
              controller: label,
              maxLength: 120,
              enabled: !busy,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: account,
              maxLength: 120,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Account (optional)',
              ),
            ),
            TextField(
              controller: secret,
              enabled: !busy,
              maxLength: 2048,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Setup key or URI',
              ),
            ),
            if (error.isNotEmpty) Text(error),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: const Text('Verify and add'),
      ),
    ],
  );
}
