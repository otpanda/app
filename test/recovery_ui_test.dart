import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/lost_access_page.dart';
import 'package:otpanda_client/recovery_contract.dart';
import 'package:otpanda_client/recovery_panel.dart';

class FakeRecovery implements RecoveryBridge {
  RecoveryStatus state;
  final List<String> log = [];
  bool failChange = false, failVerify = false, failComplete = false;
  bool unknownChange = false, unknownComplete = false;
  FakeRecovery(this.state);
  @override
  bool get recoveryAvailable => true;
  @override
  bool get enrolledClientApprovalAvailable => false;
  @override
  Future<RecoveryStatus> recoveryStatus() async => state;
  @override
  Future<void> recoveryChange(RecoveryChange c) async {
    log.add('change:${c.kind.wire}:${c.target}:${c.warningAccepted}');
    if (failChange) throw const RecoveryRefused();
    if (unknownChange) throw const RecoveryOutcomeUnknown();
  }

  @override
  Future<void> recoveryCancelRequest(String id) async => log.add('cancel:$id');
  @override
  Future<void> emailRecoveryStart(String email) async =>
      log.add('start:$email');
  @override
  Future<DateTime> emailRecoveryVerify(String email, String code) async {
    log.add('verify:$email:$code');
    if (failVerify) throw Exception('bad');
    return DateTime.utc(2026, 12, 2, 9);
  }

  @override
  Future<void> emailRecoverySendCompletionCode(String email) async =>
      log.add('complete-code:$email');
  @override
  Future<void> emailRecoveryComplete(String email, String code) async {
    log.add('complete:$email:$code');
    if (failComplete) throw const RecoveryRefused();
    if (unknownComplete) throw const RecoveryOutcomeUnknown();
  }
}

RecoveryStatus st({
  bool on = false,
  bool blocked = false,
  int keys = 2,
  EmailRecoveryRequest? req,
}) => RecoveryStatus(
  escapeEnabled: on,
  blockedByGoogleProtection: blocked,
  delayDays: 7,
  passkeys: [
    for (var i = 0; i < keys; i++)
      RecoveryPasskey('k$i', 1700000000000 + i, null),
  ],
  sessions: const [
    RecoverySession('d1', 'web', 1700000000000, null, true),
    RecoverySession('d2', 'android', 1700000100000, 1700000200000, false),
  ],
  request: req,
);

Future<void> panel(WidgetTester t, FakeRecovery f) async {
  t.view.physicalSize = const Size(400, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RecoveryPanel(key: UniqueKey(), bridge: f),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  test('status parser is strict', () {
    expect(() => RecoveryStatus.fromJson({'x': 1}), throwsFormatException);
    final s = RecoveryStatus.fromJson({
      'emailEscape': {
        'enabled': false,
        'delayDays': 7,
        'blockedByGoogleProtection': true,
      },
      'passkeys': [
        {'id': 'a', 'createdAt': 1, 'lastUsedAt': null},
      ],
      'sessions': [
        {
          'id': 'd',
          'clientKind': 'web',
          'createdAt': 2,
          'lastUsedAt': 3,
          'current': true,
        },
      ],
      'changes': [],
      'emailRecoveryRequest': {
        'requestId': 'r',
        'requestedAt': 1,
        'availableAt': 2,
        'waiting': true,
      },
    });
    expect(s.blockedByGoogleProtection, true);
    expect(s.request!.requestId, 'r');
    expect(
      RecoveryStatus.fromJson({
        'emailEscape': {'enabled': false, 'delayDays': 7},
        'passkeys': [],
        'sessions': [],
        'emailRecoveryRequest': null,
      }).request,
      isNull,
    );
    expect(
      () => RecoveryStatus.fromJson({
        'emailEscape': {'enabled': false, 'delayDays': '7'},
        'passkeys': [],
        'sessions': [],
      }),
      throwsFormatException,
    );
  });

  testWidgets('off by default; enabling needs the warning checkbox', (t) async {
    final f = FakeRecovery(st());
    await panel(t, f);
    expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value, false);
    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();
    expect(find.text('Allow email-only recovery?'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('7-day wait'),
      ),
      findsOneWidget,
    );
    await t.tap(find.text('Turn on'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(f.log, isEmpty); // disabled until acknowledged
    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.tap(find.text('Turn on'));
    await t.pumpAndSettle();
    expect(f.log, ['change:email-escape-on:null:true']);
  });

  testWidgets('blocked by Google protection: cannot turn on, says why', (
    t,
  ) async {
    final f = FakeRecovery(st(blocked: true));
    await panel(t, f);
    expect(
      t.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(find.textContaining('cannot be on together'), findsWidgets);
  });

  testWidgets('turning off asks and sends exact kind', (t) async {
    final f = FakeRecovery(st(on: true));
    await panel(t, f);
    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();
    await t.tap(find.text('Turn off'));
    await t.pumpAndSettle();
    expect(f.log, ['change:email-escape-off:null:false']);
  });

  testWidgets(
    'passkey remove targets one key; a single key is not removable here',
    (t) async {
      final one = FakeRecovery(st(keys: 1));
      await panel(t, one);
      expect(
        find.textContaining('only passkey cannot be removed here'),
        findsOneWidget,
      );
      expect(
        t
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.delete_outline).first,
            )
            .onPressed,
        isNull,
      );
      final f = FakeRecovery(st());
      await panel(t, f);
      await t.tap(find.byTooltip('Remove passkey').first);
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Remove'));
      await t.pumpAndSettle();
      expect(f.log.single, 'change:passkey-revoke:k0:false');
      f.log.clear();
      expect(find.byTooltip('Sign out this device'), findsOneWidget);
      await t.tap(find.byTooltip('Sign out this device'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await t.pumpAndSettle();
      expect(f.log.single, 'change:session-revoke:d2:false');
    },
  );

  testWidgets('refusal is generic and state reloads', (t) async {
    final f = FakeRecovery(st())..failChange = true;
    await panel(t, f);
    await t.tap(find.byTooltip('Sign out this device'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('recovery-message')), findsOneWidget);
    expect(find.textContaining('was not accepted'), findsOneWidget);
  });

  testWidgets(
    'open request is shown with cancel; honest enrolled-client note',
    (t) async {
      final f = FakeRecovery(
        st(
          on: true,
          req: const EmailRecoveryRequest('rq', 1700000000000, 1700604800000),
        ),
      );
      await panel(t, f);
      expect(find.byKey(const Key('recovery-request')), findsOneWidget);
      expect(find.textContaining('not available yet'), findsOneWidget);
      await t.tap(find.text('Cancel recovery request'));
      await t.pumpAndSettle();
      expect(f.log, ['cancel:rq']);
    },
  );

  Future<void> lost(WidgetTester t, FakeRecovery f) async {
    await t.pumpWidget(MaterialApp(home: LostAccessPage(bridge: f)));
  }

  testWidgets(
    'start journey: generic code step, verify shows date, no session claim',
    (t) async {
      final f = FakeRecovery(st());
      await lost(t, f);
      await t.tap(find.text('Start recovery'));
      await t.pump();
      await t.enterText(find.byType(TextField), 'me@example.com');
      await t.tap(find.text('Send code'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('If that address can recover this way'),
        findsOneWidget,
      );
      await t.enterText(find.byType(TextField), 'abc');
      await t.tap(find.text('Request recovery'));
      await t.pump();
      expect(find.textContaining('8-character'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'ABCD EFGH');
      await t.tap(find.text('Request recovery'));
      await t.pumpAndSettle();
      expect(f.log, ['start:me@example.com', 'verify:me@example.com:ABCDEFGH']);
      expect(find.text('Recovery requested'), findsOneWidget);
      expect(
        find.textContaining('Nothing is opened until then'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'finish journey: warns, completes, tells to sign in with new passkey',
    (t) async {
      final f = FakeRecovery(st());
      await lost(t, f);
      await t.tap(find.text('I already waited 7 days'));
      await t.pump();
      await t.enterText(find.byType(TextField), 'me@example.com');
      await t.tap(find.text('Send code'));
      await t.pumpAndSettle();
      expect(
        find.textContaining('signs out every other device'),
        findsOneWidget,
      );
      await t.enterText(find.byType(TextField), 'ABCDEFGH');
      await t.tap(find.text('Create new passkey'));
      await t.pumpAndSettle();
      expect(f.log, [
        'complete-code:me@example.com',
        'complete:me@example.com:ABCDEFGH',
      ]);
      expect(find.text('Recovery finished'), findsOneWidget);
      expect(find.textContaining('Sign in with it now'), findsOneWidget);
    },
  );

  testWidgets('failed completion changes nothing and stays on the code step', (
    t,
  ) async {
    final f = FakeRecovery(st())..failComplete = true;
    await lost(t, f);
    await t.tap(find.text('I already waited 7 days'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'me@example.com');
    await t.tap(find.text('Send code'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'ABCDEFGH');
    await t.tap(find.text('Create new passkey'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('lost-error')), findsOneWidget);
    expect(find.text('Recovery finished'), findsNothing);
  });

  testWidgets('lost reply on a change never claims it did not happen', (
    t,
  ) async {
    final f = FakeRecovery(st())..unknownChange = true;
    await panel(t, f);
    await t.tap(find.byTooltip('Sign out this device'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await t.pumpAndSettle();
    expect(
      find.textContaining('could not confirm that change'),
      findsOneWidget,
    );
    expect(find.textContaining('may have gone through'), findsOneWidget);
    expect(find.textContaining('was not accepted'), findsNothing);
  });

  testWidgets('lost reply on completion says it may have finished', (t) async {
    final f = FakeRecovery(st())..unknownComplete = true;
    await lost(t, f);
    await t.tap(find.text('I already waited 7 days'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'me@example.com');
    await t.tap(find.text('Send code'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'ABCDEFGH');
    await t.tap(find.text('Create new passkey'));
    await t.pumpAndSettle();
    expect(find.text('We could not confirm the result'), findsOneWidget);
    expect(
      find.textContaining(
        'If you created a new passkey, try signing in with it. Otherwise request a fresh code.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Nothing was changed'), findsNothing);
    expect(find.byKey(const Key('lost-error')), findsNothing);
    await t.tap(find.text('Send a fresh code'));
    await t.pump();
    expect(find.text('Send code'), findsOneWidget);
  });

  testWidgets('sections show only their part', (t) async {
    Future<void> only(Set<RecoverySection> sections) async {
      t.view.physicalSize = const Size(400, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RecoveryPanel(
                key: UniqueKey(),
                bridge: FakeRecovery(st()),
                sections: sections,
                beforeEmailRecovery:
                    sections.contains(RecoverySection.emailRecovery)
                    ? const Text('Protection lead')
                    : null,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    await only({RecoverySection.devices});
    expect(find.text('Signed-in devices'), findsOneWidget);
    expect(find.text('Recovery'), findsNothing);
    expect(find.text('Passkeys'), findsNothing);
    expect(find.text('Email-only recovery'), findsNothing);
    await only({RecoverySection.passkeys, RecoverySection.emailRecovery});
    expect(find.text('Passkeys'), findsOneWidget);
    expect(find.text('Signed-in devices'), findsNothing);
    expect(find.text('Email-only recovery'), findsOneWidget);
    expect(find.text('Protection lead'), findsOneWidget);
  });
}
