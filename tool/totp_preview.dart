import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/totp_preview_panel.dart';
import 'package:otpanda_client/totp_read_contract.dart';

// Explicit local synthetic target only, never imported by lib/main.dart.
class FictionalTransport implements SessionTransport {
  @override
  Future<SessionResponse> getManagement(String path) async {
    if (path == '/v1/manage/session') {
      return SessionResponse(
        200,
        jsonEncode({'ownerId': 'fictional', 'expiresAt': 90000}),
      );
    }
    return SessionResponse(
      200,
      jsonEncode({
        'entryId': 'fictional-entry',
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

void main() {
  final clock = Stopwatch()..start();
  final store = TotpReadStore(
    FictionalTransport(),
    monotonicMilliseconds: () => clock.elapsedMilliseconds,
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1d6643)),
      ),
      home: Scaffold(
        backgroundColor: const Color(0xffedf5f0),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: TotpPreviewPanel(
                  store: store,
                  entryId: 'fictional-entry',
                  scopeKey: 'fictional',
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
