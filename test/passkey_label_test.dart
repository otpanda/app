import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/recovery_contract.dart';
import 'package:otpanda_client/recovery_panel.dart';

import 'recovery_ui_test.dart' show FakeRecovery;

class LabelRecovery extends FakeRecovery implements PasskeyLabelBridge {
  LabelRecovery(super.state);
  bool refuse = false;
  @override
  Future<void> renamePasskey(String id, String? label) async {
    log.add('rename:$id:$label');
    if (refuse) throw const RecoveryRefused();
  }
}

class HeldLabelRecovery extends LabelRecovery {
  HeldLabelRecovery(super.state);
  Completer<RecoveryStatus>? heldStatus;
  Completer<void>? heldRename;
  int reads = 0;
  @override
  Future<RecoveryStatus> recoveryStatus() {
    reads++;
    return heldStatus?.future ?? super.recoveryStatus();
  }

  @override
  Future<void> renamePasskey(String id, String? label) async {
    log.add('rename:$id:$label');
    await heldRename?.future;
  }
}

RecoveryStatus status(List<RecoveryPasskey> keys) => RecoveryStatus(
  escapeEnabled: false,
  blockedByGoogleProtection: false,
  delayDays: 7,
  passkeys: keys,
  sessions: const [],
  request: null,
);

Future<void> show(WidgetTester t, FakeRecovery f) async {
  t.view.physicalSize = const Size(400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RecoveryPanel(
            bridge: f,
            sections: const {RecoverySection.passkeys},
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  test(
    'title is label, then provider, then Passkey; junk values are ignored',
    () {
      const a = RecoveryPasskey(
        'a',
        1,
        null,
        provider: 'Bitwarden',
        label: 'Work',
      );
      const b = RecoveryPasskey('b', 1, null, provider: 'Bitwarden');
      const c = RecoveryPasskey('c', 1, null);
      expect([a.title, b.title, c.title], ['Work', 'Bitwarden', 'Passkey']);
      final parsed = RecoveryStatus.fromJson({
        'emailEscape': {'enabled': false, 'delayDays': 7},
        'passkeys': [
          {
            'id': 'k',
            'createdAt': 1,
            'lastUsedAt': null,
            'provider': 5,
            'label': '',
          },
          {
            'id': 'm',
            'createdAt': 1,
            'lastUsedAt': null,
            'provider': 'P',
            'label': 'L',
            'x': 1,
          },
          {'id': 'o', 'createdAt': 1, 'lastUsedAt': null},
        ],
        'sessions': [],
      });
      expect(parsed.passkeys.map((p) => p.title), ['Passkey', 'L', 'Passkey']);
      expect(parsed.passkeys[1].provider, 'P');
    },
  );

  testWidgets('list shows names, provider as a hint and keeps the dates', (
    t,
  ) async {
    final f = LabelRecovery(
      status(const [
        RecoveryPasskey(
          'k1',
          1700000000000,
          1700000100000,
          provider: 'Bitwarden',
          label: 'Work laptop',
        ),
        RecoveryPasskey(
          'k2',
          1700000000000,
          null,
          provider: 'Google Password Manager',
        ),
        RecoveryPasskey('k3', 1700000000000, null),
      ]),
    );
    await show(t, f);
    expect(find.text('Work laptop'), findsOneWidget);
    expect(find.text('Bitwarden'), findsOneWidget);
    expect(find.text('Google Password Manager'), findsOneWidget);
    expect(find.text('Passkey'), findsOneWidget);
    expect(find.textContaining('Added '), findsNWidgets(3));
    expect(find.textContaining('Last used '), findsOneWidget);
  });

  testWidgets('rename sends the trimmed name and nothing else', (t) async {
    final f = LabelRecovery(
      status(const [
        RecoveryPasskey('k1', 1700000000000, null),
        RecoveryPasskey('k2', 1700000000000, null),
      ]),
    );
    await show(t, f);
    await t.tap(find.byTooltip('Rename passkey').first);
    await t.pumpAndSettle();
    expect(find.text('Name this passkey'), findsOneWidget);
    await t.enterText(find.byType(TextField), '  Phone  ');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(f.log.where((l) => l.startsWith('rename')), ['rename:k1:Phone']);
    expect(f.log.where((l) => l.startsWith('change')), isEmpty);
  });

  testWidgets('empty name removes it, unchanged or cancelled sends nothing', (
    t,
  ) async {
    final f = LabelRecovery(
      status(const [
        RecoveryPasskey('k1', 1700000000000, null, label: 'Old'),
        RecoveryPasskey('k2', 1700000000000, null),
      ]),
    );
    await show(t, f);
    await t.tap(find.byTooltip('Rename passkey').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(f.log.where((l) => l.startsWith('rename')), isEmpty);
    await t.tap(find.byTooltip('Rename passkey').first);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(f.log.where((l) => l.startsWith('rename')), ['rename:k1:null']);
    await t.tap(find.byTooltip('Rename passkey').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(f.log.where((l) => l.startsWith('rename')).length, 1);
  });

  testWidgets(
    'a refused rename says so and the last passkey can still be renamed',
    (t) async {
      final f = LabelRecovery(
        status(const [RecoveryPasskey('only', 1700000000000, null)]),
      )..refuse = true;
      await show(t, f);
      await t.tap(find.byTooltip('Rename passkey'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Key');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      expect(find.textContaining('not accepted'), findsOneWidget);
    },
  );

  testWidgets('bridge change invalidates open rename confirmation', (t) async {
    final old = LabelRecovery(
      status(const [
        RecoveryPasskey(
          'shared-id',
          1700000000000,
          null,
          label: 'Old account key',
        ),
      ]),
    );
    final next = LabelRecovery(
      status(const [
        RecoveryPasskey(
          'shared-id',
          1700000000000,
          null,
          label: 'New account key',
        ),
      ]),
    );
    await show(t, old);
    await t.tap(find.byTooltip('Rename passkey'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Wrong account rename');
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecoveryPanel(
              bridge: next,
              sections: const {RecoverySection.passkeys},
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(next.log.where((l) => l.startsWith('rename')), isEmpty);
    expect(old.log.where((l) => l.startsWith('rename')), isEmpty);
    expect(find.text('New account key'), findsOneWidget);
    expect(find.text('Old account key'), findsNothing);
  });

  for (final fail in [false, true]) {
    testWidgets(
      'late old-bridge status ${fail ? 'failure' : 'success'} cannot replace new passkeys',
      (t) async {
        final gate = Completer<RecoveryStatus>();
        final old = HeldLabelRecovery(
          status(const [RecoveryPasskey('old', 1, null, label: 'Old key')]),
        )..heldStatus = gate;
        final next = LabelRecovery(
          status(const [RecoveryPasskey('new', 1, null, label: 'New key')]),
        );
        Widget panel(LabelRecovery b) => MaterialApp(
          home: Scaffold(
            body: RecoveryPanel(
              bridge: b,
              sections: const {RecoverySection.passkeys},
            ),
          ),
        );
        await t.pumpWidget(panel(old));
        await t.pump();
        await t.pumpWidget(panel(next));
        await t.pumpAndSettle();
        if (fail) {
          gate.completeError(StateError('old read failed'));
        } else {
          gate.complete(old.state);
        }
        await t.pumpAndSettle();
        expect(find.text('New key'), findsOneWidget);
        expect(find.text('Old key'), findsNothing);
        expect(find.textContaining('could not'), findsNothing);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'old in-flight rename completion never reloads new bridge or reports saved',
    (t) async {
      final gate = Completer<void>();
      final old = HeldLabelRecovery(
        status(const [RecoveryPasskey('old', 1, null)]),
      )..heldRename = gate;
      final next = HeldLabelRecovery(
        status(const [RecoveryPasskey('new', 1, null, label: 'New key')]),
      );
      await show(t, old);
      await t.tap(find.byTooltip('Rename passkey'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Old request');
      await t.tap(find.text('Save'));
      await t.pumpAndSettle();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RecoveryPanel(
                bridge: next,
                sections: const {RecoverySection.passkeys},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(next.reads, 1);
      gate.complete();
      await t.pumpAndSettle();
      expect(next.reads, 1);
      expect(next.log, isEmpty);
      expect(find.text('Name saved.'), findsNothing);
      expect(find.text('New key'), findsOneWidget);
    },
  );
  testWidgets('bridge change invalidates open destructive confirmation', (
    t,
  ) async {
    final old = LabelRecovery(
      status(const [
        RecoveryPasskey('shared', 1, null),
        RecoveryPasskey('other', 1, null),
      ]),
    );
    final next = LabelRecovery(
      status(const [
        RecoveryPasskey('shared', 1, null),
        RecoveryPasskey('next', 1, null),
      ]),
    );
    await show(t, old);
    await t.tap(find.byTooltip('Remove passkey').first);
    await t.pumpAndSettle();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecoveryPanel(
              bridge: next,
              sections: const {RecoverySection.passkeys},
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    expect(next.log, isEmpty);
    expect(old.log, isEmpty);
  });

  testWidgets(
    'open recovery-enable dialog survives bridge swap and sends nothing',
    (t) async {
      final old = LabelRecovery(status(const []));
      final next = LabelRecovery(status(const []));
      Widget panel(LabelRecovery b) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RecoveryPanel(
              bridge: b,
              sections: const {RecoverySection.emailRecovery},
            ),
          ),
        ),
      );
      await t.pumpWidget(panel(old));
      await t.pumpAndSettle();
      final dynamic state = t.state(find.byType(RecoveryPanel));
      final pending = state.enable() as Future<void>;
      await t.pumpAndSettle();
      await t.pumpWidget(panel(next));
      await t.pumpAndSettle();
      await t.tap(find.byType(CheckboxListTile));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('Turn on'));
      await pending;
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(old.log, isEmpty);
      expect(next.log, isEmpty);
    },
  );

  testWidgets('a bridge without rename support shows no rename button', (
    t,
  ) async {
    final f = FakeRecovery(
      status(const [RecoveryPasskey('k', 1700000000000, null)]),
    );
    await show(t, f);
    expect(find.byTooltip('Rename passkey'), findsNothing);
    expect(find.byTooltip('Remove passkey'), findsOneWidget);
  });
}
