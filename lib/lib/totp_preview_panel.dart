import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'totp_read_contract.dart';

/// Synthetic-only display, deliberately absent from the application entrypoint.
/// The caller owns one store for this panel and changes scopeKey on account,
/// session, catalog or permission changes. No clipboard or automatic refresh.
class TotpPreviewPanel extends StatefulWidget {
  final TotpReadStore store;
  final String entryId;
  final Object scopeKey;
  const TotpPreviewPanel({
    super.key,
    required this.store,
    required this.entryId,
    required this.scopeKey,
  });
  @override
  State<TotpPreviewPanel> createState() => _TotpPreviewPanelState();
}

class _TotpPreviewPanelState extends State<TotpPreviewPanel>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _active = true, _loading = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.store.clear();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_active) {
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _invalidate() {
    _generation++;
    widget.store.clear();
    _loading = false;
    _error = null;
  }

  @override
  void didUpdateWidget(covariant TotpPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.entryId != widget.entryId ||
        oldWidget.scopeKey != widget.scopeKey) {
      oldWidget.store.clear();
      _invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _invalidate();
    _active = state == AppLifecycleState.resumed;
    _startTimer();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _invalidate();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_active || _loading) return;
    final generation = ++_generation, store = widget.store;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await store.load(widget.entryId);
    } catch (_) {
      if (mounted && generation == _generation) {
        _error = 'Could not load the fictional code. Try again.';
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Never retain a GeneratedTotp across builds or keep its code in state.
    final remaining = _active ? widget.store.remainingSeconds() : 0;
    final code = remaining > 0 ? widget.store.visible() : null;
    final text = code?.value;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Generated code preview',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              'Fictional data only. No account, seed or live service is connected.',
            ),
            const SizedBox(height: 24),
            Semantics(
              label: text == null
                  ? 'No fictional code displayed'
                  : 'Fictional generated code $text',
              excludeSemantics: true,
              child: Text(
                text == null
                    ? '------'
                    : '${text.substring(0, text.length ~/ 2)} ${text.substring(text.length ~/ 2)}',
                key: const ValueKey('generated-code'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 36,
                  letterSpacing: 3,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              text == null
                  ? (_active
                        ? 'Load a fresh fictional code to preview its expiry.'
                        : 'Preview paused. Return and load a fresh code.')
                  : 'Expires in $remaining ${remaining == 1 ? 'second' : 'seconds'}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_error != null) Text(_error!),
            FilledButton(
              onPressed: _active && !_loading ? _load : null,
              child: Text(_loading ? 'Loading...' : 'Load fictional code'),
            ),
            const SizedBox(height: 10),
            const Text(
              'No copy action. Leaving or changing this view clears the code.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
