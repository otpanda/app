import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/device_brand_icon.dart';
import 'package:otpanda_client/service_logo.dart';

void main() {
  test('exact aliases only, never a substring match', () {
    expect(serviceBrandFor('Mozilla'), DeviceBrand.firefox);
    expect(serviceBrandFor('  mozilla  '), DeviceBrand.firefox);
    expect(serviceBrandFor('Firefox Accounts'), DeviceBrand.firefox);
    expect(serviceBrandFor('Apple ID'), DeviceBrand.apple);
    expect(serviceBrandFor('Mozilla Fake Bank'), isNull);
    expect(serviceBrandFor('Notmozilla'), isNull);
    expect(serviceBrandFor(''), isNull);
    expect(serviceBrandFor(null), isNull);
  });

  testWidgets('shows the mark when known and the letter otherwise', (t) async {
    Widget host(String s) => MaterialApp(
      home: Scaffold(
        body: ServiceAvatar(service: s, color: Colors.green, ink: Colors.black),
      ),
    );
    await t.pumpWidget(host('Mozilla'));
    expect(find.byType(DeviceBrandIcon), findsOneWidget);
    expect(find.text('M'), findsNothing);
    await t.pumpWidget(host('Zeta'));
    expect(find.byType(DeviceBrandIcon), findsNothing);
    expect(find.text('Z'), findsOneWidget);
  });
}
