import '../transfer/batch_import_saver.dart';
import '../transfer/passkey_export_transport.dart';
import '../transfer/sealed_export_source.dart';
import '../transfer/transfer_flow.dart';

import 'dart:convert';
import 'dart:async';

import '../offline_totp/android_seed_custody.dart';
import '../offline_totp/seed_install_id.dart';
import '../offline_totp/seed_install_id_channel.dart';

import 'package:flutter/services.dart';

import '../offline_totp/android_wrapping_key_store.dart';
import '../offline_totp/native_offline_workspace_runtime.dart';
import 'native_workspace_admission.dart';
import 'native_verified_owner.dart';
import 'native_workspace_coordinator.dart';
import 'native_offline_enrollment.dart';
import '../offline_totp/seed_sync_coordinator.dart';
import '../offline_totp/seed_sync_http.dart';
import 'native_offline_setting.dart';
import '../offline_totp/seed_sync_channel.dart';
import '../offline_totp/seed_enrollment_coordinator.dart';
import '../offline_totp/seed_enrollment_http.dart';
import '../offline_totp/seed_status_channel.dart';
import '../offline_totp/seed_status_coordinator.dart';
import '../offline_totp/seed_status_http.dart';
import 'native_offline_workspace_page.dart';

import 'dart:io' show Platform;

import 'native_platform_browser.dart';

import 'package:material_ui/material_ui.dart';

import '../browser_account_page.dart';
import 'android_adapters.dart';
import 'native_assignment.dart';
import 'native_bridge.dart';
import 'native_app.dart';
import 'native_app_lock.dart';
import 'native_local_lock_recovery.dart';
import 'native_local_lock_session.dart';
import 'native_navigation.dart';
import 'native_auth.dart';
import 'native_device_proof.dart';
import 'native_device_startup.dart';
import 'native_devices.dart';
import 'native_add_device.dart';
import 'native_handoff.dart';
import 'native_passkey.dart';
import 'native_session.dart';

/// Native sign-in, entry editing and settings are supported product behavior.
/// They do not depend on opt-in build flags. Device enrollment/step-up remains
/// separately gated until its independent qualification is complete.
// Staging switch until the matching server seed-sync routes are deployed and
// authenticated enrollment is qualified. Local cold storage has its own host.
const nativeTransferEnabled = bool.fromEnvironment('NATIVE_TRANSFER_ENABLED');

const nativeSeedSyncEnabled = bool.fromEnvironment('NATIVE_SEED_SYNC_ENABLED');

const String apiOrigin = String.fromEnvironment(
  'OTPANDA_API_ORIGIN',
  defaultValue: 'https://otpanda-api.abrahammurciano.workers.dev',
);

Widget buildNativeRoot() {
  if (!Platform.isAndroid) return const NativePlatformBrowserApp();
  final google = AndroidGoogleSource();
  return _Boot(google: google);
}

/// Android composition seam for widget qualification. Production always uses
/// [buildNativeRoot] and the real session, bearer transport and Android channels.
@visibleForTesting
Widget buildAndroidNativeRootForTest({
  required NativeSessionController session,
  required BearerRequest request,
}) => _Boot(
  google: AndroidGoogleSource(),
  sessionOverride: session,
  requestOverride: request,
);

class _Boot extends StatefulWidget {
  const _Boot({
    required this.google,
    this.sessionOverride,
    this.requestOverride,
  });
  final AndroidGoogleSource google;
  final NativeSessionController? sessionOverride;
  final BearerRequest? requestOverride;
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with WidgetsBindingObserver {
  late final NativeSessionController controller;
  late final NativeSessionBridge bridge;
  late final NativeWorkspaceCoordinator workspace;
  late final NativeOfflineWorkspaceRuntime offlineRuntime;
  bool _admitting = false;
  late final NativeOfflineEnrollment offlineEnrollment;
  late final SeedStatusCoordinator offlineStatus;
  late final SeedSyncCoordinator offlinePull;
  bool _pulling = false;
  Future<void> _pullOfflineCodes() async {
    final scope = workspace.scope;
    if (!nativeSeedSyncEnabled ||
        _pulling ||
        scope == null ||
        !await _currentOfflineOwner(scope.owner)) {
      return;
    }
    _pulling = true;
    try {
      await offlinePull.sync(
        SeedSyncScope(
          owner: scope.owner,
          installId: scope.install,
          epoch: scope.epoch,
          deviceId: controller.session?.deviceId,
        ),
      );
      await offlineRuntime.refreshLocalCodes();
    } finally {
      _pulling = false;
    }
  }

  void _offlineEnrollmentChanged() {
    if (offlineEnrollment.confirmed) unawaited(_pullOfflineCodes());
  }

  int _transferFence = 0;
  BatchImportSaver? _transferSaver;
  SealedSeedExportSource? _transferSource;
  Object? _transferSession;
  void _retireTransfer() {
    _transferFence++;
    _transferSource?.cancel();
    _transferSource = null;
    _transferSaver = null;
    _transferSession = null;
  }

  void _prepareTransfer(String owner) {
    if (!nativeTransferEnabled || _transferSession == controller.session) {
      return;
    }
    _retireTransfer();
    final session = controller.session, fence = _transferFence;
    if (session == null) return;
    _transferSession = session;
    Future<bool> current() async =>
        fence == _transferFence &&
        controller.session == session &&
        await _currentOfflineOwner(owner);
    _transferSaver = BatchImportSaver(
      post: bridge.transferPost,
      passkeys: passkeys,
      current: current,
    );
    _transferSource = SealedSeedExportSource(
      PasskeyExportTransport(
        post: bridge.transferPost,
        passkeys: passkeys,
        ownerId: owner,
        deviceId: session.deviceId,
        current: current,
      ),
    );
  }

  final _verifiedOwner = NativeVerifiedOwner();
  Future<bool> _currentOfflineOwner(String owner) async =>
      mounted &&
      _verifiedOwner.ownerFor(controller.session) == owner &&
      controller.phase == NativeSessionPhase.signedIn &&
      localLock.ready &&
      !localLock.locked &&
      localLock.foreground;
  void _workspaceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _admitWorkspace() async {
    if (_admitting ||
        controller.phase != NativeSessionPhase.signedIn ||
        !localLock.ready ||
        localLock.locked) {
      return;
    }
    _admitting = true;
    final session = controller.session;
    try {
      final r = await bridge.read('/v1/manage/session');
      if (r.status != 200 ||
          controller.session != session ||
          controller.phase != NativeSessionPhase.signedIn) {
        return;
      }
      final j = jsonDecode(r.body), owner = j is Map ? j['ownerId'] : null;
      if (owner is String && owner.isNotEmpty) {
        await SeedInstallId(
          SeedInstallIdChannelStore(
            const MethodChannel('app.otpanda/seed-custody'),
          ),
        ).get();
        if (controller.session != session ||
            controller.phase != NativeSessionPhase.signedIn) {
          return;
        }
        _verifiedOwner.bind(session!, owner);
        _prepareTransfer(owner);
        offlineEnrollment.bindOwner(owner);
        await offlineEnrollment.refresh();
        await workspace.admitAuthenticated(
          owner,
          stillCurrent: () =>
              identical(controller.session, session) &&
              _verifiedOwner.ownerFor(session) == owner &&
              controller.phase == NativeSessionPhase.signedIn,
        );
        if (nativeSeedSyncEnabled) unawaited(_pullOfflineCodes());
      }
    } catch (_) {
    } finally {
      _admitting = false;
    }
  }

  Future<void> _signOut() async {
    try {
      _retireTransfer();
      _verifiedOwner.clear();
      offlineEnrollment.bindOwner(null);
      await workspace.invalidate();
      await controller.signOut();
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  final passkeys = AndroidPasskeySource();
  bool ready = false;
  final localLock = LocalLockController(ChannelLocalLock());
  late final lockNavigation = LockNavigationObserver(localLock);
  void _lockChanged() {
    navigationHistory.blocked = !localLock.ready || localLock.locked;
    if (_workspaceInitialized && localLock.locked) _retireTransfer();
    if (_workspaceInitialized) {
      workspace.localLockChanged();
      if (localLock.ready && !localLock.locked) unawaited(_admitWorkspace());
    }
  }

  bool _workspaceInitialized = false;
  final navigationHistory = NativeNavigationHistory();
  late final NativeStartupRecovery startup;
  late final NativeDevicesService devices;
  late final BearerRequest _bearer;

  @override
  void initState() {
    super.initState();
    _lockChanged();
    localLock.addListener(_lockChanged);
    WidgetsBinding.instance.addObserver(this);
    controller =
        widget.sessionOverride ??
        NativeSessionController(
          NativeAuth(
            post: androidJsonPost(apiOrigin),
            keystore: AndroidKeystoreAdapter(),
            browser: CustomTabHandoff(),
            google: widget.google,
            store: _PrefsDeviceStore(),
            apiOrigin: apiOrigin,
            launchUrl: pagesNativeLaunchUrl,
            passkeys: passkeys,
            recognition: AndroidRecognitionStore(),
          ),
        );
    _bearer = widget.requestOverride ?? androidBearerRequest(apiOrigin);
    final proof = ChannelDeviceProofSource();
    final rawEnroll = ChannelPendingStore();
    startup = NativeStartupRecovery(
      request: _bearer,
      source: proof,
      store: rawEnroll, // raw: recovery holds the lock itself
    );
    devices = NativeDevicesService(
      request: _bearer,
      session: () => controller.session,
      source: proof,
      // Every other enrollment write goes through the same lock.
      enrollStore: LockedPendingStore(rawEnroll, startup.lock),
      addStore: ChannelAddPendingStore(),
      saveConfirmed: proof.saveConfirmed,
      startup: startup,
      onGrantSpent: controller.consumeEnrollGrant,
    );
    controller.addListener(_maybeRecover);
    bridge = NativeSessionBridge(
      controller,
      _bearer,
      onLogout: () => unawaited(_signOut()),
      passkeys: passkeys,
      googleAvailability: () => widget.google.available,
      creation: passkeys,
      headerRequest: androidHeaderRequest(apiOrigin),
      deviceLabel: androidDeviceLabel,
      settingsEnabled: true,
      realtimeConnector: androidRealtimeConnector(apiOrigin),
    );
    offlineRuntime = NativeOfflineWorkspaceRuntime(
      clock: () => DateTime.now().millisecondsSinceEpoch,
    );
    workspace = NativeWorkspaceCoordinator(
      admission: NativeWorkspaceAdmission(),
      custody: AndroidSeedCustody(),
      keys: AndroidWrappingKeyStore(),
      runtime: offlineRuntime,
      locallyUnlocked: () =>
          localLock.ready && !localLock.locked && localLock.foreground,
    );
    const seedChannel = MethodChannel('app.otpanda/seed-custody');
    final seedNative = SeedSyncChannel(seedChannel);
    final statusNative = SeedStatusChannel(seedChannel);
    final statusTransport = SeedStatusHttp();
    offlineStatus = SeedStatusCoordinator(statusTransport, statusNative);
    final seedApi = SeedEnrollmentHttp(
      post: bridge.seedEnrollmentPost,
      statusTransport: statusTransport,
      signStatus:
          ({
            required owner,
            required keyId,
            required challenge,
            required expiresAt,
          }) => statusNative.signStatus(
            owner: owner,
            askedKeyId: keyId,
            challenge: challenge,
            expiresAt: expiresAt,
          ),
    );
    offlineEnrollment = NativeOfflineEnrollment(
      enrollment: SeedEnrollmentCoordinator(
        native: SeedEnrollmentNativeAdapter(seedNative),
        api: seedApi,
        passkey: SeedPasskeyStepUp(passkeys),
        isCurrent: _currentOfflineOwner,
      ),
      custody: AndroidSeedCustody(),
      sync: seedNative,
      isCurrent: _currentOfflineOwner,
      installId: () =>
          SeedInstallId(SeedInstallIdChannelStore(seedChannel)).get(),
    );
    offlinePull = SeedSyncCoordinator(
      api: SeedSyncHttp(post: bridge.seedPullPost),
      native: SeedSyncNativeAdapter(seedNative),
      custody: AndroidSeedCustody(),
      current: _currentOfflineOwner,
    );
    offlineEnrollment.addListener(_offlineEnrollmentChanged);
    workspace.addListener(_workspaceChanged);
    offlineRuntime.addListener(_workspaceChanged);
    _workspaceInitialized = true;
    localLock.recovery = NativeLocalLockRecovery(
      platform: ChannelLocalRecovery(),
      bearer: controller.accessToken,
    );
    bridge.assignment = NativeAssignmentDriver(
      post: bridge.assignmentPost,
      source: proof,
      identity: assignmentIdentity(
        readSession: () async {
          try {
            final r = await bridge.read('/v1/manage/session');
            if (r.status != 200) return null;
            final j = jsonDecode(r.body);
            return j is Map<String, dynamic> ? j : null;
          } catch (_) {
            return null;
          }
        },
        deviceId: () => controller.session?.deviceId,
        source: proof,
        post: bridge.deviceKeyPost,
      ),
    );
    Future.wait([widget.google.probe(), passkeys.probe()]).whenComplete(() {
      if (mounted) setState(() => ready = true);
    });
  }

  // Off unless NATIVE_AUTH_ENABLED. Per session (see NativeStartupRecovery):
  // sign-out or another session clears and discards; offline changes nothing.
  final _lockSession = NativeLocalLockSessionBoundary();
  void _maybeRecover() {
    if (_lockSession.update(
      controller.session?.deviceId,
      signedOut:
          controller.phase == NativeSessionPhase.signedOut ||
          controller.phase == NativeSessionPhase.signInRequired,
    )) {
      localLock.sessionChanged();
    }
    // Only a real sign-out or sign-in-required clears state and the retry
    // floor. unknown (starting) and offline are transient: nothing changes.
    if (controller.phase != NativeSessionPhase.signedIn ||
        _verifiedOwner.ownerFor(controller.session) == null) {
      _retireTransfer();
      _verifiedOwner.clear();
      offlineEnrollment.bindOwner(null);
      workspace.lock();
    }
    switch (controller.phase) {
      case NativeSessionPhase.signedIn:
        unawaited(_admitWorkspace());
        devices.sessionChanged(controller.session);
        startup.sessionChanged(controller.session);
      case NativeSessionPhase.signedOut:
      case NativeSessionPhase.signInRequired:
        navigationHistory.clear();
        devices.sessionChanged(null);
        startup.sessionChanged(null);
      case NativeSessionPhase.unknown:
      case NativeSessionPhase.offline:
        break;
    }
  }

  // Foreground-only realtime: only a resumed app holds the socket.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      bridge.realtimeSetForeground(true);
      if (nativeSeedSyncEnabled) unawaited(offlineStatus.checkAll());
      workspace.localLockChanged();
      unawaited(_admitWorkspace());
    } else if (state != AppLifecycleState.inactive) {
      _retireTransfer();
      bridge.realtimeSetForeground(false);
      workspace.lock();
    }
  }

  @override
  void dispose() {
    _retireTransfer();
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_maybeRecover);
    startup.dispose();
    devices.dispose();
    bridge.disposeRealtime();
    workspace.removeListener(_workspaceChanged);
    offlineRuntime.removeListener(_workspaceChanged);
    offlineEnrollment.removeListener(_offlineEnrollmentChanged);
    offlineEnrollment.dispose();
    workspace.dispose();
    offlineRuntime.dispose();
    navigationHistory.dispose();
    localLock.removeListener(_lockChanged);
    lockNavigation.dispose();
    localLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ready
      ? NativeApp(
          navigatorObservers: [lockNavigation],
          appWrapper: (context, child) =>
              NativeAppLock(controller: localLock, child: child),
          controller: controller,
          googleAvailable: widget.google.available,
          version: const String.fromEnvironment('APP_VERSION'),
          authBridge: bridge,
          localOfflineBuilder: (context) => workspace.hasLocalView
              ? NativeOfflineWorkspacePage(
                  runtime: offlineRuntime,
                  onReconnect: () => unawaited(controller.forceRenew()),
                )
              : null,
          signedInBuilder: (context) => NativeNavigation(
            history: navigationHistory,
            builder: (context, route, navigate) {
              final page = BrowserAccountPage(
                bridge: bridge,
                importSaver: _transferSaver,
                transferPage: _transferSaver != null && _transferSource != null
                    ? TransferFlow(
                        key: ValueKey('transfer-$_transferFence'),
                        saver: _transferSaver!,
                        exportSource: _transferSource!,
                        onSaved: () async {
                          await _admitWorkspace();
                        },
                      )
                    : const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Transfer codes is not available until this client and its server support are activated.',
                        ),
                      ),
                onWorkspaceReady: workspace.bind,
                onWorkspaceClosed: workspace.unbind,
                localSecuritySetting: Column(
                  children: [
                    LocalLockSetting(controller: localLock),
                    if (nativeSeedSyncEnabled)
                      NativeOfflineSetting(enrollment: offlineEnrollment),
                  ],
                ),
                navigation: route,
                onNavigate: navigate,
                accountOnly: true,
                signOutEnabled: true,
                workspaceEnabled: true,
                // Off with NATIVE_AUTH_ENABLED: needs the enrolled device key.
                assignmentEnabled: nativeAuthEnabled,
                // Own switch: needs the server's native entry routes.
                entryEditEnabled: true,
                entryDomainsEnabled: true,
              );
              // Only with NATIVE_AUTH_ENABLED: the way into phone sign-in.
              if (!nativeAuthEnabled) return page;
              return Stack(
                children: [
                  page,
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: SafeArea(
                      child: FloatingActionButton.extended(
                        heroTag: 'phone-sign-in',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NativeDevicesPage(service: devices),
                          ),
                        ),
                        icon: const Icon(Icons.phonelink_lock),
                        label: const Text('Phone sign-in'),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        )
      : const SizedBox.shrink();
}

// Device id is not a secret, but it only has meaning with the Keystore key.
// Stored via the native channel's SharedPreferences-backed store.
class _PrefsDeviceStore implements NativeSecureStore {
  @override
  Future<String?> readDeviceId() async =>
      nativeChannel.invokeMethod<String>('readDeviceId');
  @override
  Future<void> writeDeviceId(String id) =>
      nativeChannel.invokeMethod('writeDeviceId', {'id': id});
  @override
  Future<void> clear() => nativeChannel.invokeMethod('clearDeviceId');
}
