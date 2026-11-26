// ignore_for_file: curly_braces_in_flow_control_structures
// Screenshot-only entry (not shipped): the real ProductShell with a fake
// signed-in bridge and fictional data, to inspect desktop/mobile layout.
import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';

class Fake implements BrowserSessionBridge {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  String get status => 'restored';
  @override
  Future<void> get ready async {}

  Map<String, SessionResponse> get routes => {
    '/v1/manage/session': ok({
      'ownerId': 'o',
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 600000,
    }),
    '/v1/manage/entries': ok({
      'entries': [
        {
          'entry_id': 'e1',
          'service_name': 'Mozilla Firefox',
          'account_name': 'abrahammurciano@gmail.com',
          'capabilities': {'manage': true},
        },
        {
          'entry_id': 'e2',
          'service_name': 'GitHub',
          'account_name': 'abrahammurciano@gmail.com',
          'capabilities': {'manage': true},
        },
        {
          'entry_id': 'e3',
          'service_name': 'Google',
          'account_name': 'me@gmail.com',
          'capabilities': {'manage': true},
        },
      ],
    }),
    '/v1/manage/active-codes': ok({'records': []}),
    '/v1/manage/sources': ok({'sources': []}),
    '/v1/manage/unassigned': ok({'records': []}),
  };

  SessionResponse ok(Object o) => SessionResponse(200, jsonEncode(o));

  @override
  Future<SessionResponse> read(String path) async =>
      routes[path] ?? const SessionResponse(500, '{}');
}

Future<void> main() async {
  final bridge = Fake();
  final controller = ReadWorkspaceController(bridge: bridge);
  await controller.refresh();
  runApp(
    MaterialApp(
      theme: otpandaTheme(),
      home: ProductShell(
        controller: controller,
        profileEmail: 'abrahammurciano@gmail.com',
        onCopyAssigned: (_) async {},
        onCopyPrivate: (_) async {},
        clock: () => DateTime.now().millisecondsSinceEpoch,
        onSignedOut: () {},
        pageReload: null,
      ),
    ),
  );
}
