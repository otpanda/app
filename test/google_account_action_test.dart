import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/session_contract.dart';

import 'browser_account_test.dart' show Bridge;

class GoogleBridge extends Bridge {
  bool linked = false;
  final starts = <String>[];
  @override
  Future<void> start(String mode) async {
    starts.add(mode);
  }

  @override
  Future<SessionResponse> read(String path) async {
    if (path == '/v1/manage/account') {
      return SessionResponse(
        200,
        jsonEncode({
          'email': 'same@example.test',
          'passkeys': 1,
          'google': linked,
          'recoveryDevices': 0,
        }),
      );
    }
    return super.read(path);
  }
}

void main() {
  for (final linked in [false, true]) {
    testWidgets('signed-in Google action linked=$linked', (t) async {
      final b = GoogleBridge()
        ..status = 'restored'
        ..linked = linked;
      await t.pumpWidget(
        MaterialApp(
          home: BrowserAccountPage(
            bridge: b,
            accountOnly: true,
            loginEnabled: true,
            navigation: 'settings/account-security',
          ),
        ),
      );
      await t.pumpAndSettle();
      if (linked) {
        expect(find.text('Connected'), findsOneWidget);
        expect(find.text('Connect'), findsNothing);
      } else {
        expect(find.text('Not connected'), findsOneWidget);
        expect(b.starts, isEmpty);
        await t.tap(find.text('Connect'));
        await t.pumpAndSettle();
        expect(b.starts, ['google']);
      }
      await t.pumpWidget(const SizedBox());
    });
  }
}
