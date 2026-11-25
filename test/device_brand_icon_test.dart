import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/brand_icon_paths.dart';
import 'package:otpanda_client/device_brand_icon.dart';
import 'package:otpanda_client/recovery_contract.dart';

void main() {
  sessions();
  test('every brand path parses and fits its box', () {
    for (final b in DeviceBrand.values) {
      final spec = brandIconPaths[b.name]!;
      final r = parseSvgPath(spec.$3).getBounds();
      expect(r.isEmpty, isFalse, reason: b.name);
      expect(r.left, greaterThanOrEqualTo(-40), reason: b.name);
      expect(r.top, greaterThanOrEqualTo(-40), reason: b.name);
      expect(r.right, lessThanOrEqualTo(spec.$1 + 40), reason: b.name);
      expect(r.bottom, lessThanOrEqualTo(spec.$2 + 40), reason: b.name);
      expect(r.width, greaterThan(spec.$1 * 0.5), reason: b.name);
    }
  });

  test('labels map by exact match to a closed set', () {
    expect(deviceBrandFor('Chrome'), DeviceBrand.chrome);
    expect(deviceBrandFor(' macOS '), DeviceBrand.apple);
    expect(deviceBrandFor('Microsoft Edge'), DeviceBrand.edge);
    expect(deviceBrandFor('Chrome Evil'), isNull);
    expect(deviceBrandFor('../chrome'), isNull);
    expect(deviceBrandFor(null), isNull);
  });

  testWidgets('unknown brand shows the fallback icon', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: DeviceBrandIcon(brand: null, fallback: Icons.language),
      ),
    );
    expect(find.byIcon(Icons.language), findsOneWidget);
  });
}

void sessions() {
  RecoverySession mk(String kind, {String? b, String? o, String? n}) =>
      RecoverySession('i', kind, 1, null, false, browser: b, os: o, name: n);
  test('session titles and marks', () {
    expect(mk('web', b: 'firefox', o: 'linux').title, 'Firefox on Linux');
    expect(mk('web', b: 'safari').title, 'Safari');
    expect(mk('web', o: 'windows').title, 'Windows');
    expect(mk('web').title, 'Web');
    expect(mk('web', b: 'other', o: 'other').title, 'Web');
    expect(mk('android', n: "Abraham's Pixel 8a").title, "Abraham's Pixel 8a");
    expect(mk('android').title, 'Android app');
    expect(deviceBrandOf(mk('web', b: 'edge', o: 'windows')), DeviceBrand.edge);
    expect(deviceBrandOf(mk('web', o: 'mac')), DeviceBrand.apple);
    expect(deviceBrandOf(mk('web', b: 'samsung')), isNull);
    expect(deviceBrandOf(mk('android')), DeviceBrand.android);
  });
  test('status parse keeps only known values', () {
    final j = {
      'emailEscape': {'enabled': false, 'delayDays': 7},
      'passkeys': [],
      'emailRecoveryRequest': null,
      'sessions': [
        {
          'id': 'a',
          'clientKind': 'web',
          'createdAt': 1,
          'lastUsedAt': null,
          'current': true,
          'browser': 'firefox',
          'os': 'linux',
          'name': null,
        },
        {
          'id': 'b',
          'clientKind': 'web',
          'createdAt': 1,
          'lastUsedAt': null,
          'current': false,
          'browser': '<b>x</b>',
          'os': 5,
          'name': ' ',
        },
        {
          'id': 'c',
          'clientKind': 'android',
          'createdAt': 1,
          'lastUsedAt': null,
          'current': false,
          'name': 'Pixel',
        },
      ],
    };
    final s = RecoveryStatus.fromJson(j).sessions;
    expect(s[0].title, 'Firefox on Linux');
    expect(s[1].browser, isNull);
    expect(s[1].os, isNull);
    expect(s[1].title, 'Web');
    expect(s[2].title, 'Pixel');
  });
}
