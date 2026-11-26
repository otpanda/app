import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/auth_entry.dart';
import 'package:otpanda_client/browser_session_contract.dart';

class WaitBridge
    implements BrowserSessionBridge, AuthEntryBridge, ProtectionWatchBridge {
  void Function(String)? listener;
  int stops = 0, checks = 0;
  bool fail = false;
  @override
  String get email => 'a@example.test';
  @override
  String get pendingLabel => 'ABC123';
  @override
  void Function() protectionWatch(void Function(String reason) l) {
    listener = l;
    return () {
      stops++;
      listener = null;
    };
  }

  @override
  Future<String> protectionContinue(String action) async {
    checks++;
    expect(action, 'check');
    if (fail) throw Exception('Verification expired. Start sign-in again.');
    return 'waiting';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> open(WidgetTester t, WaitBridge b, {Object? thrown}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AuthEntry(
          bridge: b,
          status: 'extra-verification',
          message: '',
          busy: false,
          run: (f) async {
            try {
              await f();
            } catch (e) {
              errors.add(e.toString());
            }
          },
        ),
      ),
    ),
  );
  await t.pump();
}

final errors = <String>[];

void main() {
  setUp(errors.clear);
  testWidgets('busy indicator insertion keeps one pending watcher and socket', (t) async {
    final b = WaitBridge(), busy = ValueNotifier<bool>(false);
    await t.pumpWidget(ValueListenableBuilder<bool>(valueListenable: busy, builder: (_, value, __) => MaterialApp(home: Scaffold(body: AuthEntry(bridge:b,status:'extra-verification',message:'',busy:value,run:(f) async {await f();})))));
    await t.pump();
    final first=b.listener;
    for(var i=0;i<8;i++) {busy.value=true;await t.pump();busy.value=false;await t.pump();}
    expect(b.stops,0);expect(identical(b.listener,first),isTrue);
    await t.pumpWidget(const SizedBox());expect(b.stops,1);
  });
  testWidgets(
    'nudges re-read status; a definitive refusal is shown; leaving stops the watcher',
    (t) async {
      final b = WaitBridge();
      await open(t, b);
      expect(b.listener, isNotNull);
      b.listener!('open');
      b.listener!('changed');
      await t.pump();
      expect(b.checks, 2);
      expect(errors, isEmpty);
      b.fail = true;
      b.listener!('changed');
      await t.pump();
      expect(errors.single, contains('Verification expired'));
      expect(find.text('I approved on another device'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      expect(b.stops, 1);
    },
  );
  testWidgets('a nudge while busy queues exactly one more read for when idle', (
    t,
  ) async {
    final b = WaitBridge();
    final busy = ValueNotifier<bool>(true);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: busy,
            builder: (_, v, _) => AuthEntry(
              bridge: b,
              status: 'extra-verification',
              message: '',
              busy: v,
              run: (f) => f(),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    b.listener!('changed');
    b.listener!('changed');
    await t.pump();
    expect(b.checks, 0);
    busy.value = false;
    await t.pump();
    await t.pump();
    expect(b.checks, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('a bridge without the watcher keeps the manual button only', (
    t,
  ) async {
    final b = _Plain();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthEntry(
            bridge: b,
            status: 'extra-verification',
            message: '',
            busy: false,
            run: (f) => f(),
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('I approved on another device'), findsOneWidget);
  });
}

class _Plain implements BrowserSessionBridge, AuthEntryBridge {
  @override
  String get email => '';
  @override
  String get pendingLabel => 'ABC123';
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
