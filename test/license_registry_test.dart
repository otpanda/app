import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/main.dart' as app;

void main() {
  testWidgets('every shipped third-party notice is registered with its text', (
    t,
  ) async {
    app.main();
    await t.pump();
    final seen = <String, String>{};
    await for (final e in LicenseRegistry.licenses) {
      final name = e.packages.join(',');
      seen[name] = e.paragraphs.map((p) => p.text).join('\n');
    }
    for (final (name, needle) in const [
      ('Figtree', 'Figtree Project Authors'),
      ('Bricolage Grotesque', 'Bricolage Grotesque Project Authors'),
      ('Google Sans', 'Google Sans Project Authors'),
      ('2FA Directory (service names)', '2factorauth'),
      ('@zxing/library', 'Apache License'),
      ('Font Awesome Free brand icons (CC BY 4.0)', 'creativecommons.org'),
    ]) {
      expect(seen[name], contains(needle), reason: name);
    }
  });
}
