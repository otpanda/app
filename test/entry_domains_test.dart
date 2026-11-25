import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/browser_session_contract.dart';
import 'package:otpanda_client/entry_domains.dart';
import 'package:otpanda_client/entry_domains_dialog.dart';
import 'package:otpanda_client/main.dart';
import 'package:otpanda_client/product_shell.dart';
import 'package:otpanda_client/read_workspace_controller.dart';
import 'package:otpanda_client/session_contract.dart';

import 'product_shell_test.dart' show FakeTransport, now, routes;

class _Bridge extends FakeTransport
    implements EntryDomainsBridge, EntryManagementBridge {
  Map<String, List<String>> store;
  bool failRead = false, failReplace = false;
  final replaced = <(String, List<String>)>[];
  int reads = 0;
  _Bridge(super.r, this.store);
  @override
  Future<void> renameEntry(String id, String label) async {}
  @override
  Future<void> updateAccount(String id, String? a) async {}
  @override
  Future<Map<String, List<String>>> readEntryDomains() async {
    reads++;
    if (failRead) throw StateError('x');
    return store;
  }

  @override
  Future<List<String>> replaceEntryDomains(String id, List<String> d) async {
    replaced.add((id, d));
    if (failReplace) throw StateError('x');
    store = {...store, id: d};
    return d;
  }
}

ManagedEntry _entry({bool manage = true}) => ManagedEntry.fromJson({
  'entry_id': 'a',
  'service_name': 'Alpha',
  'account_name': 'me',
  'capabilities': {'manage': manage},
});

void main() {
  group('normalizeEntryDomain', () {
    test('accepts exact hosts, bare or https, lowercased', () {
      expect(normalizeEntryDomain('Example.com'), 'example.com');
      expect(
        normalizeEntryDomain(' https://Login.Example.co.uk/ '),
        'login.example.co.uk',
      );
      expect(
        normalizeEntryDomain('xn--bcher-kva.example'),
        'xn--bcher-kva.example',
      );
      expect(normalizeEntryDomain('a-b.example.test'), 'a-b.example.test');
    });
    test('never implies a parent or subdomain', () {
      expect(normalizeEntryDomain('www.example.com'), 'www.example.com');
      expect(normalizeEntryDomain('*.example.com'), isNull);
      expect(normalizeEntryDomain('.example.com'), isNull);
      expect(normalizeEntryDomain('example.com.'), isNull);
    });
    test('rejects everything that is not a bare public https host', () {
      for (final bad in [
        '',
        '   ',
        'localhost',
        'example',
        'http://example.com',
        'ftp://example.com',
        'example.com:8443',
        'user@example.com',
        'https://user:pw@example.com',
        'example.com/login',
        'https://example.com/login',
        'https://example.com?x=1',
        'example.com#x',
        '192.168.1.1',
        '10.0.0.1',
        '1.2.3.4',
        'printer.local',
        'a.localhost',
        'host.internal',
        'exa mple.com',
        'exämple.com',
        '-bad.example.com',
        'bad-.example.com',
        'a..b.com',
        'exa_mple.com',
        '${'a' * 64}.com',
        '${'a.' * 130}com',
      ]) {
        expect(normalizeEntryDomain(bad), isNull, reason: bad);
      }
    });
  });

  group('parseEntryDomains', () {
    test('reads the associations shape', () {
      final m = parseEntryDomains(
        jsonEncode({
          'associations': [
            {
              'entryId': 'a',
              'domains': ['example.com', 'b.example.com'],
            },
            {'entryId': 'b', 'domains': []},
          ],
        }),
      );
      expect(m, {
        'a': ['example.com', 'b.example.com'],
        'b': [],
      });
    });
    test('any odd shape throws instead of reading as no websites', () {
      for (final bad in [
        '[]',
        '{}',
        '{"associations":{}}',
        '{"associations":[1]}',
        '{"associations":[{"entryId":"a"}]}',
        '{"associations":[{"entryId":"a","domains":["*.x.com"]}]}',
        '{"associations":[{"entryId":"a","domains":["EXAMPLE.com"]}]}',
        '{"associations":[{"entryId":"a","domains":["a.com","a.com"]}]}',
        '{"associations":[{"entryId":"a","domains":[]},{"entryId":"a","domains":[]}]}',
        'not json',
      ]) {
        expect(
          () => parseEntryDomains(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });

  group('entryDomainsBody / entryDomainsConfirmed', () {
    test('exact keys, normalized, de-duplicated; invalid gives null', () {
      expect(entryDomainsBody('a', ['A.com', 'a.com', 'b.org']), {
        'entryId': 'a',
        'domains': ['a.com', 'b.org'],
      });
      expect(entryDomainsBody('a', []), {'entryId': 'a', 'domains': []});
      expect(
        entryDomainsBody('a', [
          for (var i = 0; i < 32; i++) 'a$i.com',
        ])!['domains'],
        hasLength(32),
      );
      expect(entryDomainsBody('a', ['*.a.com']), isNull);
      expect(entryDomainsBody('a b', ['a.com']), isNull);
      expect(
        entryDomainsBody('a', [for (var i = 0; i < 33; i++) 'a$i.com']),
        isNull,
      );
    });
    test('confirms only 200 with ok:true or the exact echoed list', () {
      expect(entryDomainsConfirmed(200, '{"ok":true}', ['a.com']), isTrue);
      expect(
        entryDomainsConfirmed(200, '{"domains":["a.com"]}', ['a.com']),
        isTrue,
      );
      expect(
        entryDomainsConfirmed(200, '{"domains":["b.com"]}', ['a.com']),
        isFalse,
      );
      expect(entryDomainsConfirmed(200, '{}', ['a.com']), isFalse);
      expect(entryDomainsConfirmed(200, '[]', ['a.com']), isFalse);
      expect(entryDomainsConfirmed(200, 'x', ['a.com']), isFalse);
      expect(entryDomainsConfirmed(204, '{"ok":true}', ['a.com']), isFalse);
      expect(entryDomainsConfirmed(500, '{"ok":true}', ['a.com']), isFalse);
    });
  });

  group('EntryDomainsDialog', () {
    Future<(_Bridge, ValueNotifier<bool?>)> open(
      WidgetTester t,
      _Bridge b, {
      bool manage = true,
    }) async {
      final result = ValueNotifier<bool?>(null);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) => TextButton(
              onPressed: () async => result.value = await showDialog<bool>(
                context: c,
                builder: (_) => EntryDomainsDialog(
                  bridge: b,
                  entry: _entry(manage: manage),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return (b, result);
    }

    testWidgets(
      'loads this entry only, add normalizes, save sends the whole list',
      (t) async {
        final b = _Bridge(routes(), {
          'a': ['one.com'],
          'z': ['other.com'],
        });
        await open(t, b);
        expect(find.text('one.com'), findsOneWidget);
        expect(find.text('other.com'), findsNothing);
        expect(
          t
              .widget<FilledButton>(find.byKey(const Key('domains-save')))
              .onPressed,
          isNull,
        );
        await t.enterText(
          find.byKey(const Key('domain-input')),
          'HTTPS://Two.Com/',
        );
        await t.tap(find.byKey(const Key('domain-add')));
        await t.pump();
        expect(find.text('two.com'), findsOneWidget);
        await t.tap(find.byKey(const Key('domain-remove-one.com')));
        await t.pump();
        await t.tap(find.byKey(const Key('domains-save')));
        await t.pumpAndSettle();
        expect(b.replaced.single.$1, 'a');
        expect(b.replaced.single.$2, ['two.com']);
        expect(find.byKey(const Key('entry-domains')), findsNothing);
      },
    );

    testWidgets(
      'rejects wildcards, paths, duplicates without calling the bridge',
      (t) async {
        final b = _Bridge(routes(), {
          'a': ['one.com'],
        });
        await open(t, b);
        for (final bad in [
          '*.one.com',
          'one.com/login',
          'ONE.com',
          'localhost',
        ]) {
          await t.enterText(find.byKey(const Key('domain-input')), bad);
          await t.tap(find.byKey(const Key('domain-add')));
          await t.pump();
          expect(
            find.byKey(const Key('domains-error')),
            findsOneWidget,
            reason: bad,
          );
        }
        expect(b.replaced, isEmpty);
        expect(
          t
              .widget<FilledButton>(find.byKey(const Key('domains-save')))
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets('a failed read offers retry and never an editor or a replace', (
      t,
    ) async {
      final b = _Bridge(routes(), {
        'a': ['one.com'],
      })..failRead = true;
      await open(t, b);
      expect(find.byKey(const Key('domains-load-error')), findsOneWidget);
      expect(find.byKey(const Key('domain-input')), findsNothing);
      b.failRead = false;
      await t.tap(find.byKey(const Key('domains-retry')));
      await t.pumpAndSettle();
      expect(find.text('one.com'), findsOneWidget);
      expect(b.replaced, isEmpty);
    });

    testWidgets(
      'an unconfirmed save says so, keeps the dialog and reports changed on Cancel',
      (t) async {
        final b = _Bridge(routes(), {})..failReplace = true;
        final (_, result) = await open(t, b);
        expect(find.byKey(const Key('domains-empty')), findsOneWidget);
        await t.enterText(find.byKey(const Key('domain-input')), 'new.com');
        await t.tap(find.byKey(const Key('domain-add')));
        await t.pump();
        await t.tap(find.byKey(const Key('domains-save')));
        await t.pumpAndSettle();
        expect(find.textContaining('Could not confirm'), findsOneWidget);
        expect(b.replaced.length, 1, reason: 'never retried');
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
        expect(result.value, isTrue);
      },
    );
  });

  group('ProductShell Websites button', () {
    Future<void> shell(
      WidgetTester t,
      FakeTransport tr, {
      required bool domains,
      bool edit = false,
    }) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final c = ReadWorkspaceController(bridge: tr, clock: () => now);
      addTearDown(c.dispose);
      await c.refresh();
      await t.pumpWidget(
        MaterialApp(
          theme: otpandaTheme(),
          home: ProductShell(
            controller: c,
            initialTab: 3,
            entryEditEnabled: edit,
            entryDomainsEnabled: domains,
            onCopyAssigned: (_) async {},
            onCopyPrivate: (_) async {},
            clock: () => now,
            onSignedOut: () {},
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    Map<String, SessionResponse> r({required bool manage}) => routes(
      entries: [
        {
          'entry_id': 'a',
          'service_name': 'Alpha',
          'account_name': 'me',
          'capabilities': {'manage': manage},
        },
      ],
    );

    testWidgets('off by default and without the bridge capability', (t) async {
      await shell(t, _Bridge(r(manage: true), {}), domains: false, edit: true);
      expect(find.byKey(const Key('domains-a')), findsNothing);
      await shell(t, FakeTransport(r(manage: true)), domains: true);
      expect(find.byKey(const Key('domains-a')), findsNothing);
    });

    testWidgets('a shared recipient gets Websites but not Edit', (t) async {
      final b = _Bridge(r(manage: false), {
        'a': ['mine.com'],
      });
      await shell(t, b, domains: true, edit: true);
      expect(find.byKey(const Key('edit-a')), findsNothing);
      await t.tap(find.byKey(const Key('domains-a')));
      await t.pumpAndSettle();
      expect(find.text('mine.com'), findsOneWidget);
    });

    testWidgets('an owner gets both buttons', (t) async {
      await shell(t, _Bridge(r(manage: true), {}), domains: true, edit: true);
      expect(find.byKey(const Key('edit-a')), findsOneWidget);
      expect(find.byKey(const Key('domains-a')), findsOneWidget);
    });
  });
}
