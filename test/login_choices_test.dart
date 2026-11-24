import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/auth_entry.dart';

import 'browser_account_test.dart' show Bridge;

void main() {
  choiceTests();
  testWidgets(
    'two login methods, separate non-Google signup and neutral remember label',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AuthEntry(
              bridge: Bridge(),
              status: 'idle',
              message: '',
              busy: false,
              run: (f) => f(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Sign in with a passkey'), findsOneWidget);
      expect(find.text('Create account with a passkey'), findsOneWidget);
      expect(find.textContaining('without Google'), findsNothing);
      expect(find.text('Continue with email'), findsNothing);
      expect(find.text('Remember this device'), findsOneWidget);
      await tester.tap(find.text('Create account with a passkey'));
      await tester.pumpAndSettle();
      expect(find.text('Create your account.'), findsOneWidget);
      expect(find.text('Send verification code'), findsOneWidget);
      expect(
        find.textContaining('Email codes are not a login method.'),
        findsOneWidget,
      );
    },
  );
}

void choiceTests() {
  testWidgets(
    'create account never starts a sign-in ceremony; sign in never opens signup',
    (t) async {
      var runs = 0;
      Widget app() => MaterialApp(
        home: Scaffold(
          body: AuthEntry(
            key: UniqueKey(),
            bridge: Bridge(),
            status: 'idle',
            message: '',
            busy: false,
            run: (f) async {
              runs++;
            },
          ),
        ),
      );
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      await t.tap(find.text('Create account with a passkey'));
      await t.pumpAndSettle();
      expect(runs, 0);
      expect(find.text('Send verification code'), findsOneWidget);
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      await t.tap(find.text('Sign in with a passkey'));
      await t.pumpAndSettle();
      expect(runs, 1);
      expect(find.text('Send verification code'), findsNothing);
    },
  );
}
