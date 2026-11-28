import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/management_contract.dart';
import 'package:otpanda_client/session_contract.dart';
import 'package:otpanda_client/sharing_contract.dart';
import 'package:otpanda_client/sharing_page.dart';

class Recording implements ManagementTransport {
  final calls = <(String, Map<String, Object?>?)>[];
  final Map<String, String> replies;
  Recording(this.replies);
  @override
  Future<SessionResponse> request(
    String path,
    String method,
    Map<String, Object?>? body,
  ) async {
    calls.add((path, body));
    return SessionResponse(
      200,
      replies[path] ??
          (path.endsWith('invite/list')
              ? '{"invites":[]}'
              : (path.endsWith('profiles/list')
                    ? '{"profiles":[]}'
                    : path.endsWith('entries/list')
                    ? '{"entries":[]}'
                    : '{"ok":true}')),
    );
  }
}

final ref = 'c' * 32;
const entries = [
  ManagedEntry('e1', 'Mozilla', 'me', true),
  ManagedEntry('e2', 'GitHub', '', true),
];
String contactsJson({Object? grant}) => jsonEncode({
  'contacts': [
    {
      'contactRef': ref,
      'since': 5,
      'hidden': false,
      'name': 'Dana Levi',
      'email': 'dana@example.test',
      'grant': grant,
    },
  ],
});

Future<Recording> open(
  WidgetTester t,
  Map<String, String> replies,
  List<String> copied,
) async {
  final rec = Recording(replies);
  t.view.physicalSize = const Size(900, 1600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SharingPage(
          client: SharingClient(rec),
          entries: entries,
          copy: (s) async => copied.add(s),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return rec;
}

void main() {
  testWidgets(
    'pending invitation from lost link remains visible and revocable',
    (t) async {
      final rec = await open(t, {
        '/v1/manage/sharing/contacts/list': '{"contacts":[]}',
        '/v1/manage/sharing/invite/list': '{"invites":[{"inviteId":"lost1","mode":"all","canDelegate":false,"createdAt":1700000000000,"expiresAt":1700086400000}]}',
      }, []);
      expect(find.byKey(const Key('pending-invite-lost1')), findsOneWidget);
      await t.tap(find.byKey(const Key('revoke-invite-lost1')));
      await t.pumpAndSettle();
      expect(rec.calls.where((c) => c.$1.endsWith('invite/revoke')).single.$2, {
        'inviteId': 'lost1',
      });
    },
  );

  testWidgets('first share is an invite link shown once and copyable', (
    t,
  ) async {
    final copied = <String>[];
    final rec = await open(t, {
      '/v1/manage/sharing/contacts/list': '{"contacts":[]}',
      '/v1/manage/sharing/invite/create':
          '{"token":"tok123","inviteId":"i1","expiresAt":9}',
    }, copied);
    expect(find.byKey(const Key('no-contacts')), findsOneWidget);
    await t.tap(find.byKey(const Key('invite-button')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('terms-confirm')));
    await t.pumpAndSettle();
    final create = rec.calls.firstWhere((c) => c.$1.endsWith('invite/create'));
    expect(create.$2, {
      'mode': 'all',
      'entryIds': <String>[],
      'canDelegate': false,
      'ttlSeconds': 86400,
    });
    expect(find.byKey(const Key('invite-link')), findsOneWidget);
    expect(
      (t.widget(find.byKey(const Key('secret-text'))) as SelectableText).data,
      contains('#/invite/tok123'),
    );
    await t.tap(find.byKey(const Key('secret-copy')));
    await t.pumpAndSettle();
    expect(copied.single, contains('#/invite/tok123'));
  });

  testWidgets(
    'remembered recipient shows name and email and re-shares without a link',
    (t) async {
      final rec = await open(t, {
        '/v1/manage/sharing/contacts/list': contactsJson(),
      }, []);
      expect(find.text('Dana Levi'), findsOneWidget);
      expect(find.text('dana@example.test'), findsOneWidget);
      await t.tap(find.byKey(Key('share-again-$ref')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('mode-allow')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('terms-confirm')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('terms-error')),
        findsOneWidget,
        reason: 'allow needs a pick',
      );
      await t.tap(find.byKey(const Key('pick-e1')));
      await t.tap(find.byKey(const Key('delegate-switch')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('terms-confirm')));
      await t.pumpAndSettle();
      final grant = rec.calls.firstWhere((c) => c.$1.endsWith('grant/create'));
      expect(grant.$2, {
        'contactRef': ref,
        'mode': 'allow',
        'entryIds': ['e1'],
        'canDelegate': true,
      });
      expect(rec.calls.any((c) => c.$1.endsWith('invite/create')), isFalse);
    },
  );

  testWidgets('stop sharing asks first, then revokes by ref', (t) async {
    final rec = await open(t, {
      '/v1/manage/sharing/contacts/list': contactsJson(
        grant: {'mode': 'all', 'canDelegate': false},
      ),
    }, []);
    expect(find.text('All accounts'), findsOneWidget);
    await t.tap(find.byKey(Key('revoke-$ref')));
    await t.pumpAndSettle();
    expect(rec.calls.where((c) => c.$1.endsWith('grant/revoke')), isEmpty);
    await t.tap(find.byKey(const Key('revoke-yes')));
    await t.pumpAndSettle();
    expect(rec.calls.firstWhere((c) => c.$1.endsWith('grant/revoke')).$2, {
      'contactRef': ref,
    });
  });

  testWidgets(
    'machine profile then token: delegated entries selectable, never available',
    (t) async {
      final copied = <String>[];
      final rec = await open(t, {
        '/v1/manage/machine/entries/list': '{"entries":[{"entryId":"e1","label":"Mozilla","account":"me","owned":true},{"entryId":"d1","label":"Netflix","account":"","owned":false}]}',
        '/v1/manage/machine/profile/create': '{"profileId":"p1"}',
        '/v1/manage/machine/token/create':
            '{"token":"mt_secret","tokenId":"t1","expiresAt":null}',
      }, copied);
      await t.tap(find.byKey(const Key('profile-button')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('terms-confirm')));
      await t.pumpAndSettle();
      expect(
        find.byKey(const Key('terms-error')),
        findsOneWidget,
        reason: 'name required',
      );
      await t.enterText(find.byKey(const Key('profile-name')), 'ci box');
      await t.tap(find.byKey(const Key('mode-deny')));
      await t.pumpAndSettle();
      expect(
        find.text('Shared with you'),
        findsOneWidget,
        reason: 'delegated entry is offered and labelled',
      );
      await t.tap(find.byKey(const Key('pick-d1')));
      await t.tap(find.byKey(const Key('terms-confirm')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('delegate-switch')), findsNothing);
      expect(rec.calls.firstWhere((c) => c.$1.endsWith('profile/create')).$2, {
        'name': 'ci box',
        'mode': 'deny',
        'entryIds': ['d1'],
      });
      expect(find.byKey(const Key('expiry-365')), findsOneWidget);
      expect(find.text('Never expires'), findsOneWidget);
      await t.tap(find.byKey(const Key('expiry-0')));
      await t.pumpAndSettle();
      final token = rec.calls.firstWhere((c) => c.$1.endsWith('token/create'));
      expect(token.$2, {'profileId': 'p1', 'ttlSeconds': null});
      expect(find.byKey(const Key('token-secret')), findsOneWidget);
      await t.tap(find.byKey(const Key('secret-done')));
      await t.pumpAndSettle();
      expect(
        find.text('mt_secret'),
        findsNothing,
        reason: 'secret not kept on the page',
      );
    },
  );

  testWidgets(
    'existing profiles hydrate from the API; token and profile revoke are separate',
    (t) async {
      final rec = await open(t, {
        '/v1/manage/machine/profiles/list': '{"profiles":[{"profileId":"p1","name":"ci box","mode":"all","createdAt":1700000000000,"revokedAt":null,"entryIds":[],"tokens":[{"tokenId":"t1","createdAt":1700000000000,"expiresAt":null,"revokedAt":null},{"tokenId":"t2","createdAt":1700000000000,"expiresAt":1700000001000,"revokedAt":null}]},{"profileId":"p2","name":"old","mode":"all","createdAt":1,"revokedAt":5,"entryIds":[],"tokens":[]}]}',
      }, []);
      expect(find.byKey(const Key('profile-p1')), findsOneWidget);
      expect(find.textContaining('never expires'), findsOneWidget);
      expect(find.textContaining('Expired'), findsOneWidget);
      expect(find.text('1 active token'), findsOneWidget);
      expect(
        find.byKey(const Key('new-token-p2')),
        findsNothing,
        reason: 'revoked profile offers no new token',
      );
      await t.ensureVisible(find.byKey(const Key('token-revoke-t1')));
      await t.tap(find.byKey(const Key('token-revoke-t1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('token-revoke-yes')));
      await t.pumpAndSettle();
      expect(rec.calls.firstWhere((c) => c.$1.endsWith('token/revoke')).$2, {
        'profileId': 'p1',
        'tokenId': 't1',
      });
      expect(rec.calls.any((c) => c.$1.endsWith('profile/revoke')), isFalse);
      await t.ensureVisible(find.byKey(const Key('profile-revoke-p1')));
      await t.tap(find.byKey(const Key('profile-revoke-p1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('profile-revoke-yes')));
      await t.pumpAndSettle();
      expect(rec.calls.firstWhere((c) => c.$1.endsWith('profile/revoke')).$2, {
        'profileId': 'p1',
      });
    },
  );
}
