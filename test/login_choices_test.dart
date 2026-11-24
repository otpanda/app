import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/auth_entry.dart';
import 'browser_account_test.dart' show Bridge;
void main(){testWidgets('two login methods, separate non-Google signup and neutral remember label',(tester)async{await tester.pumpWidget(MaterialApp(home:Scaffold(body:AuthEntry(bridge:Bridge(),status:'idle',message:'',busy:false,run:(f)=>f()))));await tester.pumpAndSettle();expect(find.text('Continue with Google'),findsOneWidget);expect(find.text('Use a passkey'),findsOneWidget);expect(find.text('Continue with email'),findsNothing);expect(find.text('Remember this device'),findsOneWidget);await tester.tap(find.text('Create an account without Google'));await tester.pumpAndSettle();expect(find.text('Create your account.'),findsOneWidget);expect(find.text('Send verification code'),findsOneWidget);expect(find.textContaining('Email codes are not a login method.'),findsOneWidget);});}
