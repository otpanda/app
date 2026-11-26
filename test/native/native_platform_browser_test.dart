import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/native/native_platform_browser.dart';
import 'package:otpanda_client/native/native_root_io.dart';

void main() {
  testWidgets(
    'non-Android native route loads its real asset and browser action without Android channels',
    (t) async {
      if (Platform.isAndroid) return;
      await t.pumpWidget(buildNativeRoot());
      await t.pumpAndSettle();
      expect(find.byType(NativePlatformBrowserApp), findsOneWidget);
      expect(find.text('Open browser app'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(t.takeException(), null);
    },
  );
}
