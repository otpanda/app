// ignore_for_file: curly_braces_in_flow_control_structures
// Screenshot-only entry (not shipped): the real BrowserAccountPage with a fake
// signed-in bridge and fictional data, to inspect account/passkey/security UI.
import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/google_link.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/recovery_contract.dart';
import 'package:otpanda_client/session_contract.dart';

/// Test hook: while set, account and recovery reads wait for it.
Completer<void>? gate;

/// Test knobs for the shown account state.
bool previewGoogle = true, previewProtection = true, previewEscape = true;

class Fake
    implements
        BrowserSessionBridge,
        AuthEntryBridge,
        FirstPasskeyBridge,
        AdditionalPasskeyBridge,
        SessionViewBridge,
        SessionContinuityBridge,
        TotpManagementBridge,
        RecoveryBridge,
        GoogleLinkBridge {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  bool get googleDisconnectAvailable => true;
  @override
  Future<void> disconnectGoogle() async {}
  @override
  Future<void> addPasskey() async {}
  @override
  String get status => 'restored';
  @override
  Future<void> get ready async {}
  @override
  void clear() {}
  @override
  void logout() {}
  @override
  int get restoredView => 0;
  @override
  void setView(int v) {}
  @override
  Future<void> maintain() async {}
  @override
  int get accessExpiresAt => DateTime.now().millisecondsSinceEpoch + 3600000;
  @override
  bool get firstPasskeyAvailable => false;
  @override
  String get email => 'alex@example.test';
  @override
  String get pendingLabel => '';
  @override
  Future<String> security(String a, [bool e = false, String p = '']) async {
    await gate?.future;
    return jsonEncode({
      'enabled': previewProtection,
      'pending': [],
      'changes': [],
    });
  }

  @override
  bool get recoveryAvailable => true;
  @override
  bool get enrolledClientApprovalAvailable => false;
  @override
  Future<RecoveryStatus> recoveryStatus() async {
    if (Uri.base.queryParameters['slow'] == '1') await Completer<void>().future;
    await gate?.future;
    final n = DateTime.now().millisecondsSinceEpoch;
    return RecoveryStatus.fromJson({
      'emailEscape': {'enabled': previewEscape, 'delayDays': 7},
      'passkeys': [
        {'id': 'p1', 'createdAt': n - 86400000 * 20, 'lastUsedAt': n - 3600000},
        {'id': 'p2', 'createdAt': n - 86400000 * 3, 'lastUsedAt': null},
      ],
      'sessions': [
        if (Uri.base.queryParameters['many'] == '1')
          for (var i = 0; i < 12; i++)
            {
              'id': 'x$i',
              'clientKind': i.isEven ? 'web' : 'android',
              'createdAt': n - 86400000 * (i + 6),
              'lastUsedAt': n - 3600000 * (i + 3),
              'current': false,
            },
        {
          'id': 's1',
          'clientKind': 'web',
          'createdAt': n - 86400000,
          'lastUsedAt': n,
          'current': true,
        },
        {
          'id': 's2',
          'clientKind': 'android',
          'createdAt': n - 86400000 * 5,
          'lastUsedAt': n - 7200000,
          'current': false,
        },
      ],
    });
  }

  @override
  Future<SessionResponse> organize(String m, String b) async =>
      const SessionResponse(404, '{}');
  @override
  Future<SessionResponse> copied(String id, int at) async =>
      const SessionResponse(404, '{}');
  @override
  Future<SessionResponse> read(String path) async {
    if (Uri.base.queryParameters['slow'] == '1' && path.endsWith('account'))
      await Completer<void>().future;
    if (path.endsWith('account')) await gate?.future;
    final now = DateTime.now().millisecondsSinceEpoch;
    Object body = {};
    if (path.endsWith('session'))
      body = {'ownerId': 'o', 'expiresAt': now + 3600000};
    if (path.endsWith('account'))
      body = {
        'email': 'alex@example.test',
        'passkeys': 2,
        'google': previewGoogle,
        'recoveryDevices': 1,
      };
    if (path.endsWith('entries')) body = {'entries': []};
    if (path.endsWith('active-codes')) body = {'records': []};
    if (path.endsWith('sources')) body = {'sources': []};
    if (path.endsWith('unassigned')) body = {'records': []};
    return SessionResponse(200, jsonEncode(body));
  }
}

void _tapLabel(String label) {
  void visit(Element e) {
    final w = e.widget;
    if (w is TextButton || w is OutlinedButton || w is FilledButton) {
      var found = false;
      void look(Element c) {
        final cw = c.widget;
        if (cw is Text && cw.data == label) found = true;
        c.visitChildren(look);
      }

      e.visitChildren(look);
      if (found) {
        ((w as ButtonStyleButton).onPressed)?.call();
        return;
      }
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}

void main() {
  final q = Uri.base.queryParameters;
  if (q['google'] == '0') previewGoogle = false;
  if (q['protection'] == '0') previewProtection = false;
  if (q['escape'] == '0') previewEscape = false;
  if (Uri.base.queryParameters['dialog'] != null) {
    Future<void>.delayed(const Duration(seconds: 3), () {
      _tapLabel('Disconnect');
    });
  }
  final route =
      Uri.base.queryParameters['route'] ?? 'settings/account-security';
  runApp(
    MaterialApp(
      theme: otpandaTheme(),
      home: BrowserAccountPage(
        bridge: Fake(),
        loginEnabled: true,
        workspaceEnabled: false,
        accountOnly: true,
        assignmentEnabled: false,
        navigation: route,
      ),
    ),
  );
}
