import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otpanda_client/account_details_page.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/organization_contract.dart';

import 'product_shell_test.dart' show ManagedFake, routes;

class SlowEdit extends ManagedFake {
  final gate = Completer<void>();
  SlowEdit() : super(routes());
  @override
  Future<void> renameEntry(String id, String name) async {
    calls2.add('rename');
    await gate.future;
  }
}

void main() {
  setUpAll(() async {
    for (final f in ['Figtree', 'BricolageGrotesque']) {
      final l = FontLoader(f);
      for (final w in f == 'Figtree' ? [400, 500, 600, 700] : [700, 800]) {
        l.addFont(
          Future.value(
            ByteData.sublistView(
              File('assets/fonts/$f-$w.ttf').readAsBytesSync(),
            ),
          ),
        );
      }
      await l.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '${Platform.environment['FLUTTER_ROOT'] ?? '/downloads/otpanda/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
  });
  testWidgets(
    'confirmed title plus later tag conflict reports partial success without uncertain lock',
    (t) async {
      final org = OrganizationStore()..reconcileEntries(['a']);
      final bridge = SlowEdit();
      String? confirmed;
      await t.pumpWidget(
        MaterialApp(
          home: AccountDetailsPage(
            entry: const ManagedEntry('a', 'Old', 'login', true),
            bridge: bridge,
            organization: org,
            isCurrent: () => true,
            onClose: () {},
            onConfirmed: ({service, account}) => confirmed = service,
            onOrganizationSaved: () async => true,
            editTags: (draft) async {
              draft.createTag('new', 'New');
              draft.setTags('a', ['new']);
            },
          ),
        ),
      );
      await t.tap(find.byKey(const Key('entry-edit')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('entry-name')), 'Confirmed');
      await t.tap(find.byKey(const Key('entry-tags')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('entry-save')));
      await t.pump();
      org.createTag('elsewhere', 'Elsewhere');
      bridge.gate.complete();
      await t.pumpAndSettle();
      expect(confirmed, 'Confirmed');
      expect(org.tags.single.label, 'Elsewhere');
      expect(
        find.textContaining('Title saved. Tags changed elsewhere.'),
        findsOneWidget,
      );
      expect(
        t.widget<FilledButton>(find.byKey(const Key('entry-save'))).onPressed,
        isNotNull,
      );
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('entry-cancel')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'Details tag edit stays staged until bottom Save, Cancel discards all tag changes',
    (t) async {
      final org = OrganizationStore()..reconcileEntries(['a']);
      final bridge = ManagedFake(routes());
      var saves = 0;
      await t.pumpWidget(
        MaterialApp(
          home: AccountDetailsPage(
            entry: const ManagedEntry('a', 'Name', 'login', true),
            bridge: bridge,
            organization: org,
            isCurrent: () => true,
            onClose: () {},
            onOrganizationSaved: () async {
              saves++;
              return true;
            },
            editTags: (draft) async {
              draft.createTag('new', 'New');
              draft.setTags('a', ['new']);
            },
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      await t.tap(find.byKey(const Key('entry-edit')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('entry-tags')));
      await t.pumpAndSettle();
      expect(find.text('New'), findsOneWidget);
      expect(org.tags, isEmpty);
      expect(saves, 0);
      await t.tap(find.byKey(const Key('entry-cancel')));
      await t.pumpAndSettle();
      expect(org.tags, isEmpty);
      expect(saves, 0);
      expect(find.text('New'), findsNothing);
      await t.tap(find.byKey(const Key('entry-edit')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('entry-tags')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('entry-save')));
      await t.pumpAndSettle();
      expect(org.tags.single.label, 'New');
      expect(org.preferencesFor('a').tagIds, {'new'});
      expect(saves, 1);
    },
  );
  testWidgets(
    'pinned bottom actions survive large text keyboard inset and scrolling',
    (t) async {
      t.view.physicalSize = const Size(320, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(1.7),
              viewInsets: EdgeInsets.only(bottom: 230),
            ),
            child: AccountDetailsPage(
              entry: const ManagedEntry('a', 'Name', 'login', true),
              bridge: ManagedFake(routes()),
              isCurrent: () => true,
              onClose: () {},
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const Key('entry-edit')));
      await t.pumpAndSettle();
      final save = t.getRect(find.byKey(const Key('entry-save'))),
          cancel = t.getRect(find.byKey(const Key('entry-cancel')));
      expect(save.bottom, lessThanOrEqualTo(410));
      expect(save.top, cancel.top);
      expect(save.width, cancel.width);
      expect(t.takeException(), isNull);
      if (Platform.environment['DETAILS_SHOTS'] != null) {
        final b = t.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        await t.runAsync(() async {
          final im = await b.toImage();
          final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
          await File('/downloads/details-large-keyboard.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          im.dispose();
        });
      }
    },
  );
  testWidgets('owner change during rename cannot send remaining account edit', (
    t,
  ) async {
    final bridge = SlowEdit();
    var current = true;
    var closed = 0;
    var confirmed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: AccountDetailsPage(
          bridge: bridge,
          entry: const ManagedEntry('a', 'Old', 'old', true),
          isCurrent: () => current,
          onClose: () => closed++,
          onConfirmed: ({service, account}) => confirmed++,
        ),
      ),
    );
    await t.tap(find.byKey(const Key('entry-edit')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('entry-name')), 'New');
    await t.enterText(find.byKey(const Key('entry-account')), 'new');
    await t.tap(find.byKey(const Key('entry-save')));
    await t.pump();
    current = false;
    bridge.gate.complete();
    await t.pumpAndSettle();
    expect(bridge.calls2, ['rename']);
    expect(closed, 0);
    expect(confirmed, 0);
  });
  testWidgets('uncertain delete cannot be repeated without reread', (t) async {
    final bridge = ManagedFake(routes())
      ..failWith = StateError('lost response');
    await t.pumpWidget(
      MaterialApp(
        home: AccountDetailsPage(
          bridge: bridge,
          entry: const ManagedEntry('a', 'Account', '', true),
          isCurrent: () => true,
          onClose: () {},
        ),
      ),
    );
    await t.tap(find.byKey(const Key('entry-edit')));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('entry-delete')));
    await t.tap(find.byKey(const Key('entry-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('entry-delete-yes')));
    await t.pumpAndSettle();
    expect(bridge.calls2, ['delete a']);
    expect(
      t.widget<TextButton>(find.byKey(const Key('entry-delete'))).onPressed,
      isNull,
    );
    expect(find.byKey(const Key('entry-error')), findsOneWidget);
  });
}
