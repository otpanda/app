import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/pull_to_refresh.dart';

Widget host(Future<void> Function() cb, {bool enabled = true}) => MaterialApp(
  home: Scaffold(
    body: PullToRefresh(
      onRefresh: cb,
      enabled: enabled,
      child: ListView(children: [for (var i = 0; i < 3; i++) Text('row $i')]),
    ),
  ),
);

void main() {
  testWidgets('touch pull down at top calls onRefresh once', (t) async {
    var n = 0;
    await t.pumpWidget(host(() async => n++));
    await t.drag(
      find.text('row 0'),
      const Offset(0, 400),
      kind: PointerDeviceKind.touch,
    );
    await t.pumpAndSettle();
    expect(n, 1);
  });

  testWidgets('disabled pull calls nothing', (t) async {
    var n = 0;
    await t.pumpWidget(host(() async => n++, enabled: false));
    await t.drag(
      find.text('row 0'),
      const Offset(0, 400),
      kind: PointerDeviceKind.touch,
    );
    await t.pumpAndSettle();
    expect(n, 0);
  });

  testWidgets('upward scroll and no gesture call nothing', (t) async {
    var n = 0;
    await t.pumpWidget(host(() async => n++));
    await t.pump(const Duration(seconds: 5));
    await t.drag(
      find.text('row 0'),
      const Offset(0, -100),
      kind: PointerDeviceKind.touch,
    );
    await t.pumpAndSettle();
    expect(n, 0);
  });
}
