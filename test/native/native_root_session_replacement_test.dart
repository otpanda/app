import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/native/native_auth.dart';
import 'package:otpanda_client/browser_account_page.dart';
import 'package:otpanda_client/native/native_root_io.dart';
import 'package:otpanda_client/native/native_workspace_admission.dart';
import 'package:otpanda_client/native/native_workspace_coordinator.dart';
import 'package:otpanda_client/offline_totp/native_offline_workspace_runtime.dart';
import 'package:otpanda_client/offline_totp/native_workspace_snapshot.dart';
import 'package:otpanda_client/offline_totp/secret_store.dart';
import 'package:otpanda_client/native/native_session.dart';
import 'package:otpanda_client/session_contract.dart';

import '../offline_totp/fake_seed_custody.dart';

// Actual _Boot root through buildAndroidNativeRootForTest with synthetic transport and
// mocked platform channels. Proves session-identity fencing of owner verification and workspace admission when the NativeSession is replaced (renewal),
// including a replacement whose access value equals the old one. Does not prove Android channel behavior.
//
// SAFETY tests assert that nothing is admitted, confirmed or bound for the replaced session. LIVENESS tests assert that the replacement session is verified
// and admitted on its own afterwards; they depend on primary's queued replacement recheck and are expected to fail until it lands.
class _Keys implements NativeKeystore {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  Future<Uint8List> signDer(Uint8List m, {bool pending = false}) async =>
      Uint8List.fromList([0x30, 6, 2, 1, 1, 2, 1, 1]);
  @override
  Future<bool> hasPendingKey() async => false;
}

class _Store implements NativeSecureStore {
  _Store(this.stored);
  final bool Function() stored;
  @override
  Future<String?> readDeviceId() async => stored() ? 'DEV' : null;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Browser implements BrowserHandoff {
  @override
  Future<Uri?> run(Uri u) async => null;
}

class _Google implements GoogleIdTokenSource {
  @override
  bool get available => false;
  @override
  Future<String?> idToken({required String nonce}) async => null;
}

class _Rig {
  _Rig({required this.equalAccess});
  final bool equalAccess;
  String responseOwner = 'owner';
  int renews = 0,
      reads = 0,
      owners = 0,
      admits = 0,
      confirms = 0,
      invalidates = 0;
  bool renewUnavailable = false, deviceStored = true, renewDeny = false;
  NativeWorkspaceCoordinator? coord;
  NativeOfflineWorkspaceRuntime? rt;
  int discovers = 0;
  final readGates = <Completer<SessionResponse>>[];
  final admitGates = <Completer<Object?>>[];
  // When true each read/admit waits on a gate the test releases; otherwise it answers at once.
  bool holdReads = false, holdAdmit = false;
  late final NativeSessionController controller;
  final now = DateTime.fromMillisecondsSinceEpoch(1000000);
  static final scope = {
    'owner': 'owner',
    'install': 'A' * 43,
    'epoch': 0,
    'namespace': 'workspace',
    'path': '/never-open',
  };

  void install() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final n in [
      'app.otpanda/google',
      'app.otpanda/passkey',
      'app.otpanda/native',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(n), (c) async => false);
    }
    m.setMockMethodCallHandler(const MethodChannel('app.otpanda/app-lock'), (
      c,
    ) async {
      if (c.method == 'enabled') return false;
      throw StateError('unexpected app-lock call ${c.method}');
    });
    m.setMockMethodCallHandler(
      const MethodChannel('app.otpanda/seed-custody'),
      (c) async {
        switch (c.method) {
          case 'readOwnerState':
            owners++;
            return {'epoch': 0, 'enabled': true};
          case 'syncInstallIdGet':
            return {'installId': 'A' * 43};
          case 'syncEnrollmentJournal':
            return null;
        }
        throw StateError('unexpected custody call ${c.method}');
      },
    );
    m.setMockMethodCallHandler(
      const MethodChannel('app.otpanda/workspace-admission'),
      (c) async {
        switch (c.method) {
          case 'admit':
            admits++;
            if (holdAdmit) {
              final g = Completer<Object?>();
              admitGates.add(g);
              return g.future;
            }
            return {'scope': scope, 'createAllowed': true};
          case 'confirm':
            confirms++;
            return {'scope': scope};
          case 'discover':
            discovers++;
            return {
              'status': 'absent',
              'scope': null,
              'reason': null,
              'createAllowed': false,
            };
          case 'invalidate':
            invalidates++;
            return {'invalidated': true};
        }
        throw StateError('unexpected admission call ${c.method}');
      },
    );
    controller = NativeSessionController(
      NativeAuth(
        post: (p, b) async {
          if (p == '/auth/native/challenge') {
            return (
              status: 200,
              body: <String, dynamic>{
                'device_id': 'DEV',
                'nonce': 'n',
                'expires_at': 5,
              },
            );
          }
          if (p == '/auth/native/renew') {
            renews++;
            if (renewUnavailable) {
              return (status: 503, body: <String, dynamic>{});
            }
            if (renewDeny) return (status: 401, body: <String, dynamic>{});
            return (
              status: 200,
              body: <String, dynamic>{
                'access': equalAccess ? 'same-access' : 'access-$renews',
                'access_expires_at': now.millisecondsSinceEpoch + 300000,
              },
            );
          }
          throw StateError('unexpected network route $p');
        },
        keystore: _Keys(),
        browser: _Browser(),
        google: _Google(),
        store: _Store(() => deviceStored),
        apiOrigin: 'https://example.invalid',
        launchUrl: (c, s) => Uri.parse('https://example.invalid'),
      ),
      clock: () => now,
    );
  }

  Future<SessionResponse> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    required String bearer,
  }) async {
    if (path == '/v1/manage/session') {
      reads++;
      if (holdReads) {
        final g = Completer<SessionResponse>();
        readGates.add(g);
        return g.future;
      }
      return SessionResponse(200, '{"ownerId":"$responseOwner"}');
    }
    return const SessionResponse(503, '{}');
  }

  void dispose() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final n in [
      'app.otpanda/google',
      'app.otpanda/passkey',
      'app.otpanda/native',
      'app.otpanda/app-lock',
      'app.otpanda/seed-custody',
      'app.otpanda/workspace-admission',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(n), null);
    }
    controller.dispose();
  }
}

Future<void> _pump(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(WidgetTester t, _Rig r) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    buildAndroidNativeRootForTest(
      session: r.controller,
      request: r.request,
      observeWorkspace: (c, rt) {
        r.coord = c;
        r.rt = rt;
      },
    ),
  );
}

Future<void> _teardown(WidgetTester t, _Rig r) async {
  await t.pumpWidget(const SizedBox.shrink());
  await _pump(t, 3);
  r.dispose();
}

void main() {
  for (final equal in [false, true]) {
    final v = equal ? 'equal-valued' : 'distinct';
    testWidgets(
      'SAFETY: $v session replaced while owner verification is pending admits nothing for the stale read',
      (t) async {
        final r = _Rig(equalAccess: equal)
          ..install()
          ..holdReads = true;
        await _mount(t, r);
        await _pump(t);
        expect(r.controller.phase, NativeSessionPhase.signedIn);
        expect(r.reads, greaterThanOrEqualTo(1));
        final oldGates = List.of(r.readGates);
        final first = r.controller.session;
        await r.controller.forceRenew();
        await _pump(t, 3);
        expect(r.controller.session, isNot(same(first)));
        for (final gate in oldGates) {
          gate.complete(
            const SessionResponse(200, '{"ownerId":"stale-owner"}'),
          );
        }
        await _pump(t);
        // All replacement reads are still held: starting a read is not proof.
        expect(r.readGates.length, greaterThan(oldGates.length));
        expect(r.admits, 0);
        expect(r.confirms, 0);
        r.holdReads = false;
        for (final gate in r.readGates.skip(oldGates.length)) {
          if (!gate.isCompleted) {
            gate.complete(const SessionResponse(200, '{"ownerId":"owner"}'));
          }
        }
        await _pump(t);
        expect(r.admits, greaterThanOrEqualTo(1));
        await _teardown(t, r);
      },
    );
    testWidgets(
      'SAFETY: $v session replaced while native admit is pending never confirms the stale admission',
      (t) async {
        final r = _Rig(equalAccess: equal)
          ..install()
          ..holdAdmit = true;
        await _mount(t, r);
        for (var i = 0; i < 40 && r.admitGates.isEmpty; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        expect(r.admitGates, hasLength(1), reason: 'admit never reached');
        await r.controller.forceRenew();
        await _pump(t, 3);
        r.holdAdmit = false;
        r.admitGates.single.complete({
          'scope': _Rig.scope,
          'createAllowed': true,
        });
        await _pump(t, 20);
        // Confirm may only follow a fresh verification and admit for the replacement session.
        expect(
          r.confirms == 0 || r.reads >= 2,
          isTrue,
          reason: 'stale admission confirmed for a replaced session',
        );
        await _teardown(t, r);
      },
    );
    testWidgets(
      'LIVENESS: $v replacement during pending owner verification is verified and admitted on its own',
      (t) async {
        final r = _Rig(equalAccess: equal)
          ..install()
          ..holdReads = true;
        await _mount(t, r);
        await _pump(t);
        await r.controller.forceRenew();
        await _pump(t, 3);
        r.holdReads = false;
        r.readGates.first.complete(
          const SessionResponse(200, '{"ownerId":"owner"}'),
        );
        await _pump(t, 25);
        expect(
          r.reads,
          greaterThanOrEqualTo(2),
          reason: 'replacement never re-verified',
        );
        expect(r.admits, greaterThanOrEqualTo(1));
        await _teardown(t, r);
      },
    );
    testWidgets(
      'LIVENESS: $v replacement during pending native admit is re-verified',
      (t) async {
        final r = _Rig(equalAccess: equal)
          ..install()
          ..holdAdmit = true;
        await _mount(t, r);
        for (var i = 0; i < 40 && r.admitGates.isEmpty; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await r.controller.forceRenew();
        await _pump(t, 3);
        r.holdAdmit = false;
        r.admitGates.first.complete({
          'scope': _Rig.scope,
          'createAllowed': true,
        });
        await _pump(t, 25);
        expect(
          r.reads,
          greaterThanOrEqualTo(2),
          reason: 'replacement never re-verified',
        );
        await _teardown(t, r);
      },
    );
  }

  testWidgets(
    'SAFETY: same-session offline renewal failure is not a sign-out (no native invalidation) and never admits or confirms on its own',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      expect(r.controller.phase, NativeSessionPhase.signedIn);
      final admitsBefore = r.admits, confirmsBefore = r.confirms;
      final session = r.controller.session;
      r.renewUnavailable = true;
      await r.controller.forceRenew();
      await _pump(t, 5);
      expect(r.controller.phase, NativeSessionPhase.offline);
      expect(
        r.controller.session,
        same(session),
        reason: 'offline keeps the session object',
      );
      expect(r.invalidates, 0);
      expect(r.admits, admitsBefore);
      expect(r.confirms, confirmsBefore);
      await _teardown(t, r);
    },
  );
  testWidgets(
    'SAFETY+LIVENESS: after offline, a renewed session must be verified again before any admission',
    (t) async {
      final r = _Rig(equalAccess: true)..install();
      await _mount(t, r);
      await _pump(t);
      final readsBefore = r.reads, admitsBefore = r.admits;
      r.renewUnavailable = true;
      await r.controller.forceRenew();
      await _pump(t, 5);
      expect(
        r.reads,
        readsBefore,
        reason: 'offline must not reuse or trigger server authority',
      );
      r.renewUnavailable = false;
      await r.controller.forceRenew();
      await _pump(t, 15);
      expect(r.controller.phase, NativeSessionPhase.signedIn);
      expect(
        r.reads,
        greaterThan(readsBefore),
        reason: 'renewed session was not verified by its own read',
      );
      expect(r.admits, greaterThanOrEqualTo(admitsBefore));
      await _teardown(t, r);
    },
  );

  // ---- R1 outcome: actual coordinator + actual runtime/snapshot through the observation seam (observeWorkspace). The runtime is opened for real
  // with in-memory secret store/custody fakes, then the root's own transitions run unchanged. Matching the root's expectations:
  //   offline/unknown: local view stays; signedOut/signInRequired: local view locked; signedIn replacement: locked then cold rediscovery queued.
  // The transfer/enrollment refusal while offline is not observable through this seam (offlineEnrollment/_verifiedOwner are private).
  Future<Directory> seedLocalView(WidgetTester t, _Rig r) async {
    final dir = Directory.systemTemp.createTempSync('root-local-view-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final c = r.coord!, rt = r.rt!;
    final scope = NativeWorkspaceScope(
      'owner',
      'A' * 43,
      0,
      'workspace',
      '${dir.path}/db',
    );
    await t.runAsync(() async {
      await rt.open(
        keys: FakeSecretStore(),
        custody: FakeSeedCustody(),
        namespace: scope.namespace,
        path: scope.path,
        owner: scope.owner,
        install: scope.install,
        epoch: 0,
        admittedFreshWorkspace: true,
        stillLocallyUnlocked: c.locallyUnlocked,
      );
      rt.publishAuthenticated(
        NativeWorkspaceSnapshot(
          ownerId: 'owner',
          installId: 'A' * 43,
          epoch: 0,
          savedAtMs: 59000,
          entries: [
            const ManagedEntry('entry', 'Saved service', 'me', true, true),
          ],
          codes: const [],
          sources: const [],
          unassigned: const [],
        ),
      );
    });
    c.scope = scope;
    expect(rt.phase, NativeOfflineWorkspacePhase.ready);
    expect(c.hasLocalView, isTrue, reason: 'seed failed');
    return dir;
  }

  bool viewAlive(_Rig r) =>
      r.coord!.hasLocalView &&
      r.rt!.snapshot?.entries.single.service == 'Saved service';

  testWidgets(
    'lock-disabled inactive and app switch retain account widget state',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      final before = t.state(find.byType(BrowserAccountPage));
      for (final phase in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]) {
        t.binding.handleAppLifecycleStateChanged(phase);
        await t.pump();
        expect(
          t.state(find.byType(BrowserAccountPage, skipOffstage: false)),
          same(before),
        );
      }
      await _teardown(t, r);
    },
  );
  testWidgets(
    'five lock-disabled inactive cycles preserve real local view without hold',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      await seedLocalView(t, r);
      for (var i = 0; i < 5; i++) {
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await t.pump();
        expect(r.rt!.phase, NativeOfflineWorkspacePhase.ready);
        expect(r.coord!.hasLocalView, isTrue);
        t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await t.pump();
        expect(r.rt!.phase, NativeOfflineWorkspacePhase.ready);
        expect(r.coord!.hasLocalView, isTrue);
      }
      await _teardown(t, r);
    },
  );
  for (final mode in ['same', 'different', 'unverified']) {
    testWidgets(
      'root render: cold scope owner, verification $mode, then outage',
      (t) async {
        final r = _Rig(equalAccess: false)..install();
        r.responseOwner = mode == 'different' ? 'different-owner' : 'owner';
        r.holdReads = mode == 'unverified';
        await _mount(t, r);
        await _pump(t);
        await seedLocalView(t, r);
        r.renewUnavailable = true;
        await r.controller.forceRenew();
        await _pump(t, 8);
        expect(r.controller.phase, NativeSessionPhase.offline);
        expect(r.rt!.snapshot, isNotNull); // Hidden, not erased or closed.
        final marker = find.text(
          'Offline. Your own saved authenticator codes still work.',
        );
        expect(marker, mode == 'different' ? findsNothing : findsOneWidget);
        await r.controller.forceRenew();
        await _pump(t, 5);
        expect(marker, mode == 'different' ? findsNothing : findsOneWidget);
        await _teardown(t, r);
      },
    );
  }
  testWidgets(
    'R1 OUTCOME: same-session offline renewal failure keeps the actual local snapshot readable',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      await seedLocalView(t, r);
      r.renewUnavailable = true;
      await r.controller.forceRenew();
      await _pump(t, 8);
      expect(r.controller.phase, NativeSessionPhase.offline);
      expect(viewAlive(r), isTrue, reason: 'offline wiped the local view');
      expect(r.rt!.phase, NativeOfflineWorkspacePhase.ready);
      await _teardown(t, r);
    },
  );
  testWidgets(
    'R1 OUTCOME: sign-in-required (renewal rejected) locks the actual local snapshot',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      await seedLocalView(t, r);
      r.renewDeny = true;
      await r.controller.forceRenew();
      await _pump(t, 8);
      expect(r.controller.phase, NativeSessionPhase.signInRequired);
      expect(r.coord!.hasLocalView, isFalse);
      expect(r.rt!.snapshot, isNull);
      await _teardown(t, r);
    },
  );
  testWidgets(
    'R1 OUTCOME: signed-out (no stored device) locks the actual local snapshot',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      await seedLocalView(t, r);
      r.deviceStored = false;
      await r.controller.forceRenew();
      await _pump(t, 8);
      expect(r.controller.phase, NativeSessionPhase.signedOut);
      expect(r.coord!.hasLocalView, isFalse);
      expect(r.rt!.snapshot, isNull);
      await _teardown(t, r);
    },
  );
  testWidgets(
    'R1 OUTCOME: local device lock hides the snapshot immediately even while offline',
    (t) async {
      final r = _Rig(equalAccess: false)..install();
      await _mount(t, r);
      await _pump(t);
      await seedLocalView(t, r);
      r.renewUnavailable = true;
      await r.controller.forceRenew();
      await _pump(t, 3);
      expect(viewAlive(r), isTrue);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(r.rt!.snapshot, isNull);
      await _teardown(t, r);
    },
  );
}
