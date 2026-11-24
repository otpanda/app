// Synthetic browser harness only. Not imported by the production entrypoint.
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/assignment_dialog.dart';
import 'package:otpanda_client/browser_session.dart';
import 'package:otpanda_client/browser_session_contract.dart';

void main() async {
  final bridge = createBrowserSession();
  await bridge.ready;
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: AssignmentDialog(
            bridge: bridge as AssignmentBridge,
            sourceId: 'fixture-source',
            eventId: 'fixture-event',
            entryId: 'fixture-entry',
          ),
        ),
      ),
    ),
  );
}
