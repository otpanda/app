import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'browser_session_contract.dart';
import 'otpauth.dart';
import 'public_service_catalog.dart';
import 'service_directory.dart';
import 'service_logo.dart';
import 'qr_camera.dart';
import 'session_contract.dart';
import 'totp_batch.dart';
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

  /// Shared in-memory batch of upcoming codes. Without it, or when the batch
  /// has nothing usable for this entry, one code at a time is requested.
  final TotpBatchStore? batch;
  const TotpEntryDialog({
    super.key,
    required this.bridge,
    required this.entryId,
    this.batch,
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
      if (_current() == null &&
          DateTime.now().millisecondsSinceEpoch >= retryAt) {
        load();
      }
      setState(() {});
    });
  }

  /// A batch code that is current now wins; otherwise the single-code store.
  ({String value, int left})? _current() {
    final b = widget.batch?.codeFor(widget.entryId);
    if (b != null) return (value: b.value, left: b.secondsLeft);
    final c = store.visible();
    return c == null ? null : (value: c.value, left: store.remainingSeconds());
  }

  Future<void> load() async {
    if (loading || paused) return;
    loading = true;
    try {
      final batch = widget.batch;
      if (batch != null && !batch.omitted(widget.entryId)) {
        // A failed batch never blocks the dialog: only an authorization
        // failure surfaces, anything else falls back to one code.
        try {
          await batch.ensure([widget.entryId]);
        } on ClientFailure catch (e) {
          if (e.status == 401 || e.status == 403) rethrow;
        }
      }
      if (_current() == null) await store.load(widget.entryId);
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
    final code = _current(), left = code?.left ?? 0;
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
                      final current = _current();
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

typedef QrCameraBuilder = Widget Function(
  void Function(String text) onText,
  void Function(QrCameraProblem problem) onError,
);

Widget _defaultCamera(
  void Function(String text) onText,
  void Function(QrCameraProblem problem) onError,
) => QrCameraView(onText: onText, onError: onError);

/// Two stages. 1: camera opens at once (or a key field after the toggle) and
/// the first valid key advances. 2: name and account, prefilled from the key.
Future<String?> addTotpDialog(
  BuildContext context,
  TotpManagementBridge bridge, {
  QrCameraBuilder camera = _defaultCamera,
  ServiceDirectory? directory,
}) async => showDialog<String>(
  context: context,
  builder: (_) =>
      _AddTotp(bridge: bridge, camera: camera, directory: directory),
);

class _AddTotp extends StatefulWidget {
  final TotpManagementBridge bridge;
  final QrCameraBuilder camera;
  final ServiceDirectory? directory;
  const _AddTotp({required this.bridge, required this.camera, this.directory});
  @override
  State<_AddTotp> createState() => _AddTotpState();
}

class _AddTotpState extends State<_AddTotp> {
  final label = TextEditingController(),
      account = TextEditingController(),
      key = TextEditingController();
  OtpauthImport? found;

  /// The catalogue service the user chose. Kept until the user removes or
  /// replaces it: editing the name never rebinds or drops it.
  PublicService? chosen;
  bool manual = false, busy = false, showKey = false, noCamera = false;
  QrCameraProblem? problem;
  String scanError = '', error = '';

  @override
  void dispose() {
    key.clear();
    label.dispose();
    account.dispose();
    key.dispose();
    super.dispose();
  }

  void advance(OtpauthImport v) {
    if (found != null || !mounted) return;
    key.clear();
    setState(() {
      found = v;
      label.text = v.name;
      account.text = v.account;
      error = '';
    });
  }

  void onScan(String text) {
    if (found != null) return;
    try {
      advance(parseOtpauth(text));
    } on OtpauthException catch (e) {
      if (mounted && scanError != e.message) {
        setState(() => scanError = e.message);
      }
    }
  }

  void onProblem(QrCameraProblem p) {
    if (!mounted) return;
    setState(() {
      problem = p;
      // No camera at all (a desktop without one): go straight to manual
      // entry. The button still offers the camera again. A denied permission
      // keeps its own explanation, since the user can fix that.
      if (p == QrCameraProblem.unavailable && found == null) {
        manual = true;
        noCamera = true;
        showKey = false;
        scanError = '';
        key.clear();
      }
    });
  }

  Future<void> save() async {
    final v = found;
    if (busy || v == null) return;
    if (label.text.trim().isEmpty) {
      setState(() => error = 'Enter a name.');
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
        v.uri,
        catalogId: chosen?.id,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not add authenticator. Check the key and verify with an existing passkey.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget stageOne() {
    final valid = parseSetupKey(key.text) != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!manual)
          SizedBox(
            height: 260,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: problem == null
                  ? widget.camera(onScan, onProblem)
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          problem == QrCameraProblem.permissionDenied
                              ? 'Camera permission is off. Allow camera access in settings, or enter the key manually.'
                              : 'The camera is not available. Enter the key manually.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
          )
        else ...[
          if (noCamera)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'No camera found. Enter the key manually.',
                key: Key('no-camera-note'),
              ),
            ),
          TextField(
            controller: key,
            autofocus: true,
            obscureText: !showKey,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 2048,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Setup key',
              helperText: 'Key from the service, or an otpauth link',
              suffixIcon: IconButton(
                tooltip: showKey ? 'Hide key' : 'Show key',
                icon: Icon(showKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => showKey = !showKey),
              ),
            ),
            onSubmitted: (_) {
              final v = parseSetupKey(key.text);
              if (v != null) advance(v);
            },
          ),
        ],
        if (!manual && scanError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(scanError),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() {
            manual = !manual;
            noCamera = false;
            problem = null;
            scanError = '';
            showKey = false;
            key.clear();
          }),
          child: Text(manual ? 'Scan QR code' : 'Enter key manually'),
        ),
        if (manual) ...[
          const SizedBox(height: 4),
          FilledButton(
            onPressed: valid
                ? () {
                    final v = parseSetupKey(key.text);
                    if (v != null) advance(v);
                  }
                : null,
            child: const Text('Next'),
          ),
        ],
      ],
    );
  }

  Future<void> pickService() async {
    final selected = await showDialog<PublicService>(
      context: context,
      builder: (_) => PublicServicePicker(directory: widget.directory),
    );
    if (selected != null && mounted) {
      setState(() {
        chosen = selected;
        label.text = selected.name;
      });
    }
  }

  Widget servicePicker() => chosen == null
      ? Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('find-service'),
            icon: const Icon(Icons.search),
            label: const Text('Find a service'),
            onPressed: busy ? null : pickService,
          ),
        )
      : ListTile(
          key: const Key('chosen-service'),
          contentPadding: EdgeInsets.zero,
          leading: ServiceAvatar(
            service: chosen!.name,
            serviceId: chosen!.id,
            color: const Color(0xffdff3e8),
            ink: const Color(0xff17372a),
            directory: widget.directory,
          ),
          title: Text(chosen!.name),
          subtitle: Text(chosen!.host),
          trailing: IconButton(
            key: const Key('remove-service'),
            tooltip: 'Remove service',
            icon: const Icon(Icons.close),
            onPressed: busy ? null : () => setState(() => chosen = null),
          ),
        );

  Widget stageTwo() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'The key is encrypted in your cloud account so OTPanda can generate codes. Verify with a passkey to save.',
      ),
      const SizedBox(height: 8),
      servicePicker(),
      if (found?.issuer != null) Text('Issuer: ${found!.issuer}'),
      TextField(
        controller: label,
        maxLength: 120,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Display name'),
      ),
      TextField(
        controller: account,
        maxLength: 120,
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Account (optional)'),
      ),
      if (error.isNotEmpty) Text(error),
      if (busy) const LinearProgressIndicator(),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    // No dismissal (outside tap, back, route pop) while saving or verifying:
    // a finished add must always return its entry id so the shell can refresh.
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Add authenticator'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: found == null ? stageOne() : stageTwo(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (found != null)
          FilledButton(
            onPressed: busy ? null : save,
            child: const Text('Verify and add'),
          ),
      ],
    ),
  );
}
