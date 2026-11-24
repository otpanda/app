import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'session_contract.dart';
import 'totp_preview_panel.dart';
import 'totp_read_contract.dart';

/// Only for the fictional local catalog, never for connected account entries.
class FictionalTotpDialog extends StatefulWidget {
  final String entryId, service, account;
  const FictionalTotpDialog({
    super.key,
    required this.entryId,
    required this.service,
    required this.account,
  });
  @override
  State<FictionalTotpDialog> createState() => _FictionalTotpDialogState();
}

class _FictionalTotpDialogState extends State<FictionalTotpDialog> {
  final _clock = Stopwatch()..start();
  late final _transport = _FictionalTransport(widget.entryId);
  late final _store = TotpReadStore(
    _transport,
    monotonicMilliseconds: () => _clock.elapsedMilliseconds,
  );

  @override
  void dispose() {
    _store.clear();
    _clock.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    namesRoute: true,
                    header: true,
                    child: const Text(
                      'Fictional entry preview',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close generated-code preview',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(widget.service),
            if (widget.account.isNotEmpty) Text(widget.account),
            const SizedBox(height: 12),
            TotpPreviewPanel(
              store: _store,
              entryId: widget.entryId,
              scopeKey: widget.entryId,
            ),
          ],
        ),
      ),
    ),
  );
}

// No HTTP client, browser bridge, credentials or seed. Exact in-process fixtures.
class _FictionalTransport implements SessionTransport {
  final String entryId;
  _FictionalTransport(this.entryId);
  @override
  Future<SessionResponse> getManagement(String path) async {
    if (path == '/v1/manage/session') {
      return SessionResponse(
        200,
        jsonEncode({'ownerId': 'fictional', 'expiresAt': 90000}),
      );
    }
    final expected =
        '/v1/manage/totp-code?${Uri(queryParameters: {'entry': entryId}).query}';
    if (path != expected) throw const ClientFailure();
    return SessionResponse(
      200,
      jsonEncode({
        'entryId': entryId,
        'code': '001234',
        'period': 30,
        'validFrom': 30,
        'validUntil': 60,
        'serverNow': 50000,
      }),
    );
  }

  @override
  Future<void> close() async {}
}
