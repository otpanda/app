import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:otpanda_client/main.dart' show otpandaTheme;
import 'package:otpanda_client/native/native_add_device.dart';
import 'package:otpanda_client/native/native_approval_routes.dart';
import 'package:otpanda_client/native/native_auth.dart' show NativeSession;
import 'package:otpanda_client/native/native_bridge.dart' show BearerRequest;
import 'package:otpanda_client/native/native_device_proof.dart';
import 'package:otpanda_client/native/native_device_startup.dart';
import 'package:otpanda_client/native/native_devices.dart';
import 'package:otpanda_client/session_contract.dart';

const _spki =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf6D2ZU6KOMIilG/FwV5O17ameP6NzDCyEStU1W9XlRvZoCWby8+xl9fZiQZMHRumylHG9THkZN3P2SFrBpu/NA==';
final _kid = 'k_${'a1' * 20}';

class _Src implements DeviceProofSource {
  _Src({this.hasLocalKey = true});
  final bool hasLocalKey;
  int signs = 0;
  @override
  Future<DeviceProofAvailability> availability() async =>
      DeviceProofAvailability.available;
  @override
  Future<bool> hasKey() async => hasLocalKey;
  @override
  Future<Uint8List?> publicKeyOrNull() async =>
      hasLocalKey ? base64.decode(_spki) : null;
  @override
  Future<Uint8List> createKeyForEnrollment() async => base64.decode(_spki);
  @override
  Future<Uint8List> sign(DeviceProofFields f, {String? displayText}) async {
    signs++;
    throw const DeviceProofFailure(DeviceProofFailureKind.unsupportedOs);
  }
}

class _Raw implements PendingEnrollStore {
  @override
  Future<PendingRead> read() async => const PendingRead.none();
  @override
  Future<void> write(PendingRecord r) async {}
  @override
  Future<void> clear() async {}
}

class _Add implements AddPendingStore {
  @override
  Future<AddPendingRead> read() async => const AddPendingRead.none();
  @override
  Future<void> write(AddPendingRecord r) async {}
  @override
  Future<void> clear() async {}
}

const _s = NativeSession('DEV', 'tok', 99999999);
final _now = DateTime.now().millisecondsSinceEpoch;

BearerRequest _req(Map<String, dynamic> Function(String, String?) f) =>
    (m, p, {body, query, required bearer}) async {
      expect(bearer, 'tok');
      return SessionResponse(200, jsonEncode(f(p, body)));
    };

NativeDevicesService _svc(
  _Src src,
  BearerRequest req, {
  NativeSession? s = _s,
}) {
  final lock = AsyncLock();
  final raw = _Raw();
  final st = NativeStartupRecovery(
    request: req,
    source: src,
    store: raw,
    enabled: true,
    lock: lock,
  );
  return NativeDevicesService(
    request: req,
    session: () => s,
    source: src,
    enrollStore: LockedPendingStore(raw, lock),
    addStore: _Add(),
    saveConfirmed: (o, k) async {},
    startup: st,
    now: () => _now,
  );
}

Widget _app(NativeDevicesService v) => MaterialApp(
  theme: otpandaTheme(),
  home: NativeDevicesPage(service: v),
);

void main() {
  test(
    'the service refuses an enroll store that is not on the startup lock',
    () {
      final lock = AsyncLock();
      final raw = _Raw();
      final st = NativeStartupRecovery(
        request: _req((p, b) => {}),
        source: _Src(),
        store: raw,
        enabled: true,
        lock: lock,
      );
      expect(
        () => NativeDevicesService(
          request: _req((p, b) => {}),
          session: () => _s,
          source: _Src(),
          enrollStore: raw,
          addStore: _Add(),
          saveConfirmed: (o, k) async {},
          startup: st,
        ),
        throwsArgumentError,
      );
      expect(
        () => NativeDevicesService(
          request: _req((p, b) => {}),
          session: () => _s,
          source: _Src(),
          enrollStore: LockedPendingStore(raw, AsyncLock()),
          addStore: _Add(),
          saveConfirmed: (o, k) async {},
          startup: st,
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets(
    'enrolled phone: pending approval is listed with its readable text; Approve reaches the driver and the refused host step-up leaves everything unconfirmed',
    (t) async {
      final src = _Src();
      final req = _req((p, b) {
        switch (p) {
          case '/v1/manage/session':
            return {'ownerId': 'O'};
          case '/v1/manage/account':
            return {'email': 'me@example.com'};
          case '/v1/manage/device-key/enroll-status':
            return {'status': 'enrolled', 'keyId': _kid};
          default:
            return {};
        }
      });
      // approval/status is a POST; the helper above returns {} for it, so use a
      // dedicated request that also serves the status rows.
      final both =
          (
            String m,
            String p, {
            String? body,
            Map<String, String>? query,
            required String bearer,
          }) async {
            if (p == '/v1/manage/approval/status') {
              return SessionResponse(
                200,
                jsonEncode({
                  'ownerId': 'O',
                  'generation': 1,
                  'pending': [
                    {
                      'changeId': 'C1',
                      'kind': 'passkey-add',
                      'target': null,
                      'requesterLabel': 'Firefox on Linux',
                      'requesterKind': 'web',
                      'requestedAt': _now - 60000,
                      'expiresAt': _now + 540000,
                    },
                  ],
                }),
              );
            }
            return req(m, p, body: body, query: query, bearer: bearer);
          };
      final v = _svc(src, both);
      await t.pumpWidget(_app(v));
      await t.pumpAndSettle();
      expect(
        find.text('This phone can approve sign-in changes.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Requested 1 minute ago from a browser (Firefox on Linux)',
        ),
        findsOneWidget,
      );
      expect(find.text('Set up this phone'), findsNothing);
      await t.tap(find.text('Approve'));
      await t.pumpAndSettle();
      // approve-begin is not served: refused before any prompt, nothing signed.
      expect(src.signs, 0);
      expect(find.byKey(const ValueKey('message')), findsOneWidget);
      expect(find.textContaining('Approved.'), findsNothing);
    },
  );

  testWidgets(
    'no local key but a grant: only first set-up is offered; without a grant: ask-another-phone is offered',
    (t) async {
      final req = _req(
        (p, b) => switch (p) {
          '/v1/manage/session' => {'ownerId': 'O'},
          '/v1/manage/account' => {'email': 'me@example.com'},
          _ => {},
        },
      );
      final withGrant = _svc(
        _Src(hasLocalKey: false),
        req,
        s: const NativeSession(
          'DEV',
          'tok',
          99999999,
          enrollGrant: 'otpda_grant',
        ),
      );
      await t.pumpWidget(_app(withGrant));
      await t.pumpAndSettle();
      expect(find.text('Set up this phone'), findsOneWidget);
      expect(find.text('Ask another phone to approve this one'), findsNothing);
      final noGrant = _svc(_Src(hasLocalKey: false), req);
      await t.pumpWidget(_app(noGrant));
      await t.pumpAndSettle();
      expect(find.text('Set up this phone'), findsNothing);
      expect(
        find.text('Ask another phone to approve this one'),
        findsOneWidget,
      );
      expect(find.text('Check approval'), findsNothing);
    },
  );
}
