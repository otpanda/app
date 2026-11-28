// Screenshot-only entry (not shipped): the real Gmail source widgets with a
// fake bridge. ?s=ready|blocked|pending|consent|disc-ok|disc-blocked|disc-stuck
import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/gmail_source.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/session_contract.dart';

class Fake implements GmailSourceBridge {
  final Map<String, Object?> status;
  final GmailDisconnectResult result;
  Fake(this.status, this.result);
  @override
  Future<SessionResponse> gmailSourceStatus() async =>
      SessionResponse(200, jsonEncode(status));
  @override
  Future<String> takeGmailResult() async => '';
  @override
  Future<void> connectGmail() async {}
  @override
  Future<GmailDisconnectResult> disconnectGmail(
    String id, {
    String rules = 'keep',
  }) async => result;
}

Element? findText(String text) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(walk);
  return hit;
}

void tap(String text) {
  final e = findText(text);
  if (e == null) return;
  final box = e.renderObject as RenderBox;
  final p = box.localToGlobal(box.size.center(Offset.zero));
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(position: p, viewId: view.viewId),
  );
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(position: p, viewId: view.viewId),
  );
}

void main() {
  final s = Uri.base.queryParameters['s'] ?? 'ready';
  const ok = GmailDisconnectResult(disconnected: true, artifactsRemoved: true);
  final status = <String, Object?>{
    'ready': true,
    'passkeyRequired': false,
    'pending': s == 'pending' ? 3 : 0,
    'full': false,
    'skipped': s == 'pending' ? {'too_large': 1} : {},
    'leftoverLabels': s == 'blocked' ? 1 : 0,
    'leftoverFilters': s == 'blocked' ? 1 : 0,
    'lifecycleBlocked': s == 'blocked',
  };
  final disconnect = s.startsWith('disc');
  final bridge = Fake(
    status,
    s == 'disc-blocked'
        ? const GmailDisconnectResult(
            disconnected: true,
            lifecycleBlocked: true,
          )
        : s == 'disc-stuck'
        ? const GmailDisconnectResult(
            disconnected: false,
            lifecycleBlocked: true,
          )
        : ok,
  );
  runApp(
    MaterialApp(
      theme: otpandaTheme(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Sources')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GmailSourceConnect(bridge: bridge),
              const SizedBox(height: 10),
              Card(
                child: ListTile(
                  title: const Text('otpanda.app@gmail.com'),
                  subtitle: const Text('GMAIL'),
                ),
              ),
              GmailSourceDisconnect(
                bridge: bridge,
                sourceId: 'source',
                label: 'otpanda.app@gmail.com',
                onChanged: () {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  void later(int ms, String label) =>
      Timer(Duration(milliseconds: ms), () => tap(label));
  if (s == 'consent') later(3000, 'Connect Gmail');
  if (disconnect) {
    later(3000, 'Disconnect Gmail');
    later(5000, 'Verify and disconnect');
  }
}
