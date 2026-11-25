import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/extension_popup.dart';
import 'package:otpanda_client/session_contract.dart';

class _Bridge
    implements BrowserSessionBridge, RealtimeBridge, ExtensionPopupBridge {
  final reads = <String>[];
  List<String> codeEntries = ['e1'];
  void Function(String)? hint;
  int now;
  _Bridge(this.now);
  @override
  bool get extensionPopup => true;
  @override
  Future<void> get ready async {}
  @override
  String get status => 'restored';
  @override
  Future<SessionResponse> read(String path) async {
    reads.add(path);
    if (path == '/v1/manage/entries') {
      return SessionResponse(
        200,
        jsonEncode({
          'entries': [
            {
              'entry_id': 'e1',
              'service_name': 'Svc',
              'account_name': 'a',
              'capabilities': {'manage': true},
            },
          ],
        }),
      );
    }
    return SessionResponse(
      200,
      jsonEncode({
        'records': [
          for (final id in codeEntries)
            {
              'entryId': id,
              'code': '123456',
              'receivedAt': now - 1000,
              'expiresAt': now + 3600000,
            },
        ],
      }),
    );
  }

  @override
  void Function() realtimeSubscribe(void Function(String) listener) {
    hint = listener;
    return () => hint = null;
  }

  @override
  Future<void> start(String mode) async {}
  @override
  Future<void> passkey() async {}
  @override
  void clear() {}
  @override
  void logout() {}
  @override
  Future<SessionResponse> organize(String m, String b) async =>
      const SessionResponse(503, '{}');
  @override
  Future<SessionResponse> copied(String e, int c) async =>
      const SessionResponse(503, '{}');
}

void main() {
  testWidgets('unresolved entry ids cost no extra entries reads per hint', (
    tester,
  ) async {
    var t = 1800000000000;
    final b = _Bridge(t)..codeEntries = ['e1', 'ghost'];
    await tester.pumpWidget(
      MaterialApp(
        home: ExtensionPopupView(bridge: b, clock: () => t),
      ),
    );
    Future<void> advance(int ms) async {
      t += ms;
      b.now = t;
      await tester.pump(Duration(milliseconds: ms));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
    }

    await advance(100);
    int entries() => b.reads.where((p) => p.endsWith('/entries')).length;
    int codes() => b.reads.where((p) => p.endsWith('/active-codes')).length;
    expect(
      [codes(), entries()],
      [1, 1],
      reason: 'open: one codes, one entries',
    );
    for (var i = 0; i < 4; i++) {
      await advance(2500);
      b.hint!('changed');
      await advance(100);
    }
    expect(codes(), 5, reason: 'each spaced hint refetches codes');
    expect(
      entries(),
      1,
      reason: 'a persistent unknown id must not refetch entries per hint',
    );
    // A different unknown id may fetch once, then is suppressed too.
    b.codeEntries = ['e1', 'ghost2'];
    await advance(10500);
    b.hint!('changed');
    await advance(100);
    expect(entries(), 2, reason: 'a new unknown id fetches entries once');
    await advance(2500);
    b.hint!('changed');
    await advance(100);
    expect(entries(), 2, reason: 'same unresolved id suppressed');
    // A burst of hints is one in-flight plus one trailing, spaced >= 2s.
    final before = codes();
    for (var i = 0; i < 6; i++) {
      b.hint!('changed');
    }
    await advance(100);
    await advance(2500);
    expect(codes() - before, lessThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new unknown id inside the 10s limit is fetched at 10s, not 30s',
    (tester) async {
      var t = 1800000000000;
      final b = _Bridge(t)..codeEntries = ['e1', 'ghost'];
      await tester.pumpWidget(
        MaterialApp(
          home: ExtensionPopupView(bridge: b, clock: () => t),
        ),
      );
      Future<void> advance(int ms) async {
        t += ms;
        b.now = t;
        await tester.pump(Duration(milliseconds: ms));
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 1));
        }
      }

      int entries() => b.reads.where((p) => p.endsWith('/entries')).length;
      await advance(100);
      expect(entries(), 1);
      // ghost was seen at open (suppressed). A different id appears 3s later,
      // still inside the 10s window after the last unknown fetch.
      await advance(3000);
      b.codeEntries = ['e1', 'ghost', 'new1'];
      b.hint!('changed');
      await advance(100);
      expect(entries(), 1, reason: 'inside the 10s limit: no immediate fetch');
      await advance(5000);
      expect(entries(), 1, reason: 'still waiting');
      await advance(2500);
      expect(entries(), 2, reason: 'fetched at about 10s, far before 30s');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
