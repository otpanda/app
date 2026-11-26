import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'totp_batch.dart';

/// The live authenticator code on a list tile, read from the shared in-memory
/// [TotpBatchStore]. It makes no request of its own. Every build asks the store,
/// which checks the server-time anchor and the hard expiry, so an expired batch
/// never shows a code. The once-a-second repaint is local and stops while the
/// page is hidden.
class TotpTileCode extends StatefulWidget {
  final TotpBatchStore batch;
  final String entryId;
  final bool Function() hidden;
  final Color muted;
  const TotpTileCode({
    super.key,
    required this.batch,
    required this.entryId,
    required this.hidden,
    required this.muted,
  });
  @override
  State<TotpTileCode> createState() => _TotpTileCodeState();
}

class _TotpTileCodeState extends State<TotpTileCode> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !widget.hidden()) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  static String spaced(String c) =>
      c.length == 6 ? '${c.substring(0, 3)} ${c.substring(3)}' : c;

  @override
  Widget build(BuildContext context) {
    final code = widget.hidden() ? null : widget.batch.codeFor(widget.entryId);
    if (code == null) {
      return Text(
        'Code not loaded',
        style: TextStyle(fontSize: 12, color: widget.muted),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              spaced(code.value),
              style: const TextStyle(
                fontFamily: 'Figtree',
                fontFeatures: [FontFeature.tabularFigures()],
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${code.secondsLeft} s',
              style: TextStyle(fontSize: 11, color: widget.muted),
            ),
          ],
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: 'Copy code',
          onPressed: () => Clipboard.setData(ClipboardData(text: code.value)),
          icon: const Icon(Icons.copy_outlined, size: 18),
        ),
      ],
    );
  }
}
