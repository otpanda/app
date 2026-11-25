import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../main.dart' show green, ink, line, muted;
import 'native_add_device.dart';
import 'native_adopt_device.dart';
import 'native_approval_prompt.dart';
import 'native_approval_routes.dart';
import 'native_auth.dart' show NativeSession;
import 'native_bridge.dart';
import 'native_device_proof.dart';
import 'native_device_routes.dart';
import 'native_device_startup.dart';
import 'native_enroll_recovery.dart';

/// Everything the "Phone sign-in" page does, behind one object so the page is
/// only display. Nothing here runs unless the page is opened, and the page is
/// only reachable when NATIVE_AUTH_ENABLED is on. Step-up signing stays
/// refused by the host until that flag is released.
class NativeDevicesService extends ChangeNotifier {
  NativeDevicesService({
    required this.request,
    required this.session,
    required this.source,
    required this.enrollStore,
    required this.addStore,
    required this.saveConfirmed,
    required this.startup,
    this.onGrantSpent,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    if (enrollStore is! LockedPendingStore ||
        !identical((enrollStore as LockedPendingStore).lock, startup.lock)) {
      throw ArgumentError(
        'enrollment writes must use LockedPendingStore(raw, startup.lock)',
      );
    }
  }
  /// Called once the one-time enrollment grant has been sent to the server
  /// (the server consumes it on finish). The same grant also backs the first
  /// passkey, so the owner of the session must stop offering it.
  final void Function()? onGrantSpent;
  final BearerRequest request;
  final NativeSession? Function() session;
  final DeviceProofSource source;

  /// Must be the LockedPendingStore on the same lock as [startup].
  final PendingEnrollStore enrollStore;
  final AddPendingStore addStore;
  final Future<void> Function(String ownerId, String keyId) saveConfirmed;
  final NativeStartupRecovery startup;
  final int Function() _now;

  bool loading = false, busy = false;
  String? ownerId, email, ownKeyId, message, addFingerprint;
  ServerKeyStatus? serverStatus;
  ApprovalStatus? approvals;
  bool addPending = false;

  /// A key exists on this phone but the server state could not be read. Only
  /// Refresh is offered; no set-up or add is ever offered on a failed read.
  bool checkFailed = false;
  bool get hasGrant => session()?.enrollGrant != null;

  /// The server holds no active key for this phone (never made, or absent) and
  /// the read succeeded.
  bool get notEnrolled =>
      !checkFailed &&
      (serverStatus == null || serverStatus == ServerKeyStatus.absent);
  int now() => _now();

  /// Set when add-device found the server already holds this phone's key.
  /// Bound to owner, device and session epoch; cleared on any session change
  /// and after an adopt settles.
  ({String ownerId, String deviceId, String keyId, int epoch})? _addAdopt;
  bool get addNeedsAdopt =>
      _addAdopt != null &&
      _addAdopt!.epoch == _epoch &&
      _addAdopt!.ownerId == ownerId &&
      _addAdopt!.deviceId == session()?.deviceId;

  /// Link this phone is offered from either origin.
  bool get canLink =>
      !checkFailed &&
      (addNeedsAdopt ||
          startup.current?.result.outcome == RecoveryOutcome.needsAdopt);

  int _epoch = 0; // bumped only by a real session change
  int _refreshSeq = 0; // bumped by every refresh; stale reads are dropped
  String? _boundDevice;

  void _clear() {
    ownerId = email = ownKeyId = message = addFingerprint = null;
    serverStatus = null;
    approvals = null;
    addPending = checkFailed = loading = false;
    _addAdopt = null;
  }

  /// Call on every real session change: null for sign-out or sign-in
  /// required, the session for signed-in. A different device or no session
  /// aborts anything in flight and clears every shown value.
  void sessionChanged(NativeSession? s) {
    if (s == null || (_boundDevice != null && _boundDevice != s.deviceId)) {
      _epoch++;
      _boundDevice = s?.deviceId;
      _clear();
      notifyListeners();
      return;
    }
    _boundDevice = s.deviceId;
  }

  DevicePost _post(String access) => bearerDevicePost(request, () => access);

  void _say(String? m) {
    message = m;
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _get(String path, String bearer) async {
    try {
      final r = await request('GET', path, bearer: bearer);
      if (r.status != 200) return null;
      final j = jsonDecode(r.body);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  bool _alive(int epoch, String device, [int? seq]) =>
      epoch == _epoch &&
      (seq == null || seq == _refreshSeq) &&
      session()?.deviceId == device;

  Future<void> refresh() async {
    final s = session();
    if (s == null) {
      sessionChanged(null);
      return;
    }
    final e = _epoch, q = ++_refreshSeq;
    final device = s.deviceId, access = s.access;
    loading = true;
    notifyListeners();
    try {
      final o = (await _get('/v1/manage/session', access))?['ownerId'];
      final em = (await _get('/v1/manage/account', access))?['email'];
      if (!_alive(e, device, q)) return;
      final owner = o is String && o.isNotEmpty ? o : null;
      final mail = em is String && em.isNotEmpty ? em : null;
      final spki = await source.publicKeyOrNull();
      if (!_alive(e, device, q)) return;
      ServerKeyStatus? st;
      String? kid;
      ApprovalStatus? appr;
      var failed = owner == null;
      if (spki != null && owner != null) {
        final r = await DeviceStatusRoutes(_post(access))
            .status(publicKeyDigest(spkiToJwk(spki)));
        if (!_alive(e, device, q)) return;
        if (r == null) {
          failed = true;
        } else {
          st = r.status;
          if (r.status == ServerKeyStatus.enrolled) {
            kid = r.keyId;
            appr = await ApprovalRoutes(_post(access)).status();
            if (!_alive(e, device, q)) return;
          }
        }
      }
      final pending = (await addStore.read()).record != null;
      if (!_alive(e, device, q)) return;
      ownerId = owner;
      email = mail;
      ownKeyId = kid;
      serverStatus = st;
      approvals = appr;
      addPending = pending;
      checkFailed = failed;
      if (failed) message = 'Could not check this phone. Nothing was changed.';
    } catch (_) {
      if (!_alive(e, device, q)) return;
      checkFailed = true;
      message = 'Could not check this phone. Nothing was changed.';
    } finally {
      if (e == _epoch && q == _refreshSeq) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Values an action runs with, copied once at the start so a later change
  /// of session, owner or email cannot leak into a half-finished action.
  _Snap? _take({bool needEmail = false}) {
    final s = session();
    final o = ownerId;
    if (s == null || o == null || (needEmail && email == null)) return null;
    return _Snap(
      s.deviceId,
      s.access,
      s.enrollGrant,
      o,
      email,
      ownKeyId,
      _epoch,
    );
  }

  Future<void> _guard(Future<void> Function() f) async {
    if (busy) return;
    final e = _epoch;
    busy = true;
    notifyListeners();
    try {
      await f();
    } catch (_) {
      if (e == _epoch) message = 'That did not finish. Nothing was confirmed.';
    } finally {
      // busy tracks the real run, not the session: after sign-out an old run
      // may still be writing, and no new run starts until it has settled.
      busy = false;
      notifyListeners();
    }
  }

  /// A settled change: drop the old startup result so it cannot be shown or
  /// acted on again, then read fresh state.
  Future<void> _done() async {
    _addAdopt = null;
    startup.invalidate();
    await refresh();
  }

  /// First durable enrollment with the memory-only grant, under the shared lock.
  Future<void> enroll() => _guard(() async {
    final n = _take();
    final g = n?.grant;
    if (n == null || g == null) {
      return _say('Sign in again to set up this phone.');
    }
    final r = await enrollDevice(
      source,
      DeviceEnrollRoutes(_post(n.access), grant: g).enrollment,
      expectedOwnerId: n.ownerId,
      sessionDeviceId: n.deviceId,
      onEnrolled: (k) => saveConfirmed(n.ownerId, k),
      store: enrollStore,
      now: _now,
    );
    // Anything past a refused start may have reached the server (an unknown
    // finish included): the grant is treated as spent and never reused.
    if (r.outcome != EnrollmentOutcome.notStarted) onGrantSpent?.call();
    if (!_alive(n.epoch, n.deviceId)) return;
    _say(switch (r.outcome) {
      EnrollmentOutcome.enrolled => 'This phone is set up.',
      EnrollmentOutcome.methodExists => 'This account already has a sign-in method. Sign in with it to add this phone.',
      EnrollmentOutcome.retryLater => 'The server is busy. Try again shortly.',
      EnrollmentOutcome.unknown =>
        'Not confirmed. Your key is kept; reopen this page to check.',
      EnrollmentOutcome.rejected => 'The server did not accept this.',
      EnrollmentOutcome.notStarted => 'This phone cannot do that right now.',
    });
    if (r.outcome == EnrollmentOutcome.enrolled) {
      await _done();
    } else {
      await refresh();
    }
  });

  /// The server already holds this phone's key: re-link it with one unlock.
  Future<void> adopt() => _guard(() async {
    final n = _take(needEmail: true);
    final cur = startup.current?.result;
    final fromStartup = cur?.outcome == RecoveryOutcome.needsAdopt;
    final aa = _addAdopt;
    final fromAdd =
        !fromStartup &&
        aa != null &&
        n != null &&
        aa.epoch == n.epoch &&
        aa.ownerId == n.ownerId &&
        aa.deviceId == n.deviceId;
    // Only a live needsAdopt (startup or add-device) may start an adopt; after
    // one settles nothing can run it a second time.
    final expected = fromStartup ? cur?.keyId : (fromAdd ? aa.keyId : null);
    if (n == null || expected == null) {
      return _say('Could not read the account. Nothing was changed.');
    }
    final r = await AdoptDriver(
      source: source,
      routes: DeviceStatusRoutes(_post(n.access)),
      ownerId: n.ownerId,
      accountEmail: n.email!,
      expectedKeyId: expected,
      now: _now,
      onAdopted: (k) => saveConfirmed(n.ownerId, k),
      clearAnchor: () async {
        if (fromStartup) {
          await enrollStore.clear();
        } else {
          await addStore.clear();
        }
      },
    ).adopt();
    if (!_alive(n.epoch, n.deviceId)) return;
    _say(switch (r) {
      AdoptOutcome.adopted => 'This phone is linked.',
      AdoptOutcome.cancelled => 'Cancelled. Nothing changed.',
      AdoptOutcome.notConfirmed => 'Not confirmed. Nothing changed; try again.',
      AdoptOutcome.refused => 'This check did not pass, so nothing was signed.',
      AdoptOutcome.notStarted => 'This phone cannot do that right now.',
    });
    if (r == AdoptOutcome.adopted) {
      await _done();
    } else {
      await refresh();
    }
  });

  Future<void> approve(ApprovalRow row) => _guard(() async {
    final n = _take(needEmail: true);
    final st = approvals;
    if (n == null || st == null || n.ownKeyId == null) {
      return _say('Could not read the account. Nothing was changed.');
    }
    final r = await ApprovalDriver(
      source: source,
      routes: ApprovalRoutes(_post(n.access)),
      ownerId: n.ownerId,
      ownKeyId: n.ownKeyId!,
      accountEmail: n.email!,
      now: _now,
    ).approve(st, row);
    if (!_alive(n.epoch, n.deviceId)) return;
    _say(switch (r) {
      ApproveOutcome.approved => 'Approved.',
      ApproveOutcome.cancelled => 'Cancelled. Nothing was approved.',
      ApproveOutcome.notConfirmed =>
        'Not confirmed. The request is still open; check again.',
      ApproveOutcome.approvedOrExpired =>
        'The request is gone. It was either approved or it expired.',
      ApproveOutcome.refused =>
        'This check did not pass, so nothing was signed.',
    });
    await refresh();
  });

  AddDeviceDriver _add(_Snap n) => AddDeviceDriver(
    source: source,
    routes: AddDeviceRoutes(_post(n.access)),
    store: addStore,
    ownerId: n.ownerId,
    sessionDeviceId: n.deviceId,
    statusRoutes: DeviceStatusRoutes(_post(n.access)),
    onEnrolled: (k) => saveConfirmed(n.ownerId, k),
    now: _now,
  );

  /// This is the NEW phone asking an enrolled phone to approve it.
  Future<void> requestAdd() => _guard(() async {
    final n = _take();
    if (n == null) {
      return _say('Could not read the account. Nothing was changed.');
    }
    final r = await _add(n).request();
    if (!_alive(n.epoch, n.deviceId)) return;
    if (r.outcome == AddOutcome.requested) addFingerprint = r.fingerprint;
    _say(switch (r.outcome) {
      AddOutcome.requested => 'Open OTPanda on your other phone and approve. Compare the fingerprint.',
      AddOutcome.inProgress =>
        'A request is already in progress. Use Check approval.',
      _ => 'Could not send the request. Nothing was changed.',
    });
    await refresh();
  });

  Future<void> checkAdd() => _guard(() async {
    final n = _take();
    if (n == null) {
      return _say('Could not read the account. Nothing was changed.');
    }
    final r = await _add(n).checkApprovalAndFinish();
    if (!_alive(n.epoch, n.deviceId)) return;
    _say(switch (r.outcome) {
      AddOutcome.enrolled => 'This phone is added.',
      AddOutcome.notApprovedYet => 'Not approved yet.',
      AddOutcome.approvalExpired =>
        'The request expired. You can send a new one.',
      AddOutcome.needsAdopt =>
        'The server already has this phone. Use "Link this phone".',
      AddOutcome.revokedNeedsMethod =>
        'This phone key was revoked. Sign in with another method.',
      AddOutcome.waiting => 'Checking. Try again in a minute.',
      AddOutcome.absentCleared =>
        'Nothing was added. You can send a new request.',
      AddOutcome.refused => 'This check did not pass, so nothing was signed.',
      _ => 'Not confirmed. Nothing was lost; try again.',
    });
    if (r.outcome == AddOutcome.needsAdopt && r.keyId != null) {
      _addAdopt = (
        ownerId: n.ownerId,
        deviceId: n.deviceId,
        keyId: r.keyId!,
        epoch: n.epoch,
      );
    }
    if (r.outcome == AddOutcome.enrolled) {
      addFingerprint = null;
      await _done();
    } else {
      await refresh();
    }
  });
}

class _Snap {
  const _Snap(
    this.deviceId,
    this.access,
    this.grant,
    this.ownerId,
    this.email,
    this.ownKeyId,
    this.epoch,
  );
  final String deviceId, access, ownerId;
  final String? grant, email, ownKeyId;
  final int epoch;
}

class NativeDevicesPage extends StatefulWidget {
  const NativeDevicesPage({super.key, required this.service});
  final NativeDevicesService service;
  @override
  State<NativeDevicesPage> createState() => _NativeDevicesPageState();
}

class _NativeDevicesPageState extends State<NativeDevicesPage> {
  @override
  void initState() {
    super.initState();
    widget.service.refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Phone sign-in')),
    body: ListenableBuilder(
      listenable: Listenable.merge([widget.service, widget.service.startup]),
      builder: (context, _) {
        final v = widget.service;
        final rec = v.startup.current?.result.outcome;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (v.loading) const LinearProgressIndicator(),
            if (v.message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  v.message!,
                  key: const ValueKey('message'),
                  style: const TextStyle(color: ink),
                ),
              ),
            _Section(
              title: 'This phone',
              children: [
                Text(_status(v, rec), style: const TextStyle(color: muted)),
                const SizedBox(height: 10),
                if (v.notEnrolled && v.hasGrant)
                  FilledButton(
                    onPressed: v.busy ? null : v.enroll,
                    style: FilledButton.styleFrom(backgroundColor: green),
                    child: const Text('Set up this phone'),
                  ),
                if (v.canLink)
                  FilledButton(
                    onPressed: v.busy ? null : v.adopt,
                    style: FilledButton.styleFrom(backgroundColor: green),
                    child: const Text('Link this phone'),
                  ),
                if (v.notEnrolled && !v.hasGrant) ...[
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onPressed: v.busy ? null : v.requestAdd,
                    child: const Text('Ask another phone to approve this one'),
                  ),
                ],
                if (v.addPending && !v.checkFailed) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onPressed: v.busy ? null : v.checkAdd,
                    child: const Text('Check approval'),
                  ),
                ],
                if (v.addFingerprint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      v.addFingerprint!,
                      key: const ValueKey('add-fingerprint'),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: ink,
                      ),
                    ),
                  ),
              ],
            ),
            if (v.approvals != null && !v.canLink && !v.checkFailed)
              _Section(
                title: 'Waiting for you',
                children: [
                  SizedBox(
                    height: 420,
                    child: ApprovalListView(
                      status: v.approvals!,
                      accountEmail: v.email ?? '',
                      clock: v.now,
                      busyChangeId: v.busy ? '*' : null,
                      onApprove: v.approve,
                      onDismiss: (_) {},
                    ),
                  ),
                ],
              ),
            TextButton(
              onPressed: v.loading ? null : v.refresh,
              child: const Text('Refresh'),
            ),
          ],
        );
      },
    ),
  );

  String _status(NativeDevicesService v, RecoveryOutcome? rec) {
    if (v.checkFailed) {
      return 'Could not check this phone. Use Refresh to try again.';
    }
    if (v.serverStatus == ServerKeyStatus.enrolled && !v.canLink) {
      return 'This phone can approve sign-in changes.';
    }
    if (v.canLink) {
      return 'The server already knows this phone. Link it to use it again.';
    }
    if (rec == RecoveryOutcome.revokedNeedsMethod ||
        v.serverStatus == ServerKeyStatus.revoked) {
      return 'This phone key was revoked. Sign in with another method to add it again.';
    }
    if (rec == RecoveryOutcome.waiting) {
      return 'Checking an earlier attempt. Try again in a minute.';
    }
    return 'This phone is not set up for approvals yet.';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}
