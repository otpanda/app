import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';

import 'product_shell_test.dart' show FakeTransport, routes;

Future<(FakeTransport, int Function(), void Function(int))> setup(
  WidgetTester t, {
  Future<void> Function()? reload,
}) async {
  t.view.physicalSize = const Size(360, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  var clock = 1000000;
  final tr = FakeTransport(routes());
  final c = ReadWorkspaceController(bridge: tr, clock: () => clock);
  addTearDown(c.dispose);
  await c.refresh();
  await t.pumpWidget(
    MaterialApp(
      theme: otpandaTheme(),
      home: ProductShell(
        controller: c,
        onCopyAssigned: (_) async {},
        onCopyPrivate: (_) async {},
        clock: () => clock,
        onSignedOut: () {},
        pageReload: reload,
      ),
    ),
  );
  await t.pumpAndSettle();
  return (
    tr,
    () => clock,
    (int v) {
      clock = v;
      c.tick(); // the account page timer does this once a second
    },
  );
}

Future<void> pullDown(WidgetTester t) async {
  await t.drag(
    find.text('Your codes'),
    const Offset(0, 400),
    kind: PointerDeviceKind.touch,
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('native: pull refreshes data in place once the gate opens', (
    t,
  ) async {
    final (tr, now, set) = await setup(t);
    final before = tr.calls;
    await pullDown(t); // inside the 15s gate: nothing
    expect(tr.calls, before);
    set(now() + 15000);
    await pullDown(t);
    expect(tr.calls, greaterThan(before));
    expect(find.text('Your codes'), findsOneWidget);
  });

  testWidgets('web: pull reloads the page right away, never refetches data', (
    t,
  ) async {
    var reloads = 0;
    final (tr, now, set) = await setup(t, reload: () async => reloads++);
    final before = tr.calls;
    await pullDown(t); // inside the refetch cooldown: still reloads
    expect(reloads, 1);
    set(now() + 15000);
    await pullDown(t);
    expect(reloads, 2);
    expect(tr.calls, before);
  });

  testWidgets('web: pull reloads while a refresh is still loading', (t) async {
    var reloads = 0;
    final (tr, _, _) = await setup(t, reload: () async => reloads++);
    tr.handler = (_) =>
        Future.delayed(const Duration(seconds: 30), () => throw 0);
    await pullDown(t);
    expect(reloads, 1);
  });

  testWidgets('desktop platforms get no pull indicator at all', (t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    var reloads = 0;
    final tr = FakeTransport(routes());
    final c = ReadWorkspaceController(bridge: tr, clock: () => 1000000);
    addTearDown(c.dispose);
    await c.refresh();
    await t.pumpWidget(
      MaterialApp(
        theme: otpandaTheme().copyWith(platform: TargetPlatform.windows),
        home: ProductShell(
          controller: c,
          onCopyAssigned: (_) async {},
          onCopyPrivate: (_) async {},
          clock: () => 1000000,
          onSignedOut: () {},
          pageReload: () async => reloads++,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsNothing);
    await pullDown(t);
    expect(reloads, 0);
  });

  testWidgets('manual Refresh control is absent', (t) async {
    await setup(t);
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(find.text('Refresh'), findsNothing);
  });
}
