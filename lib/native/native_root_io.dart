import '../transfer/owner_bound_import_coordinator.dart';
import '../transfer/android_import_picker.dart';
import '../import_recovery_journal.dart';
import '../transfer/verified_import_flow.dart';

import 'dart:convert';
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
const String apiOrigin = String.fromEnvironment(
  'OTPANDA_API_ORIGIN',
  defaultValue: 'https://otpanda-api.abrahammurciano.workers.dev',
);

/// Root file boundary: a document selected across an identity/lock change is
/// discarded before parsing. The picker itself carries no authority.
@visibleForTesting
Future<String?> guardedImportFile({
  required Future<bool> Function() current,
  required Future<String?> Function() pick,
}) async {
  if (!await current()) return null;
  final text = await pick();
  return await current() ? text : null;
}

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
  final passkeys = AndroidPasskeySource();
  bool ready = false;
  bool _importForeground = true;
  final _importPicker = AndroidImportPicker();
  OwnerBoundImportCoordinator? _importCoordinator;
  (int, String)? _importCoordinatorKey;
  static const _importEnabled = bool.fromEnvironment(
    'TOTP_IMPORT_ENABLED',
    defaultValue: false,
  );
  final localLock = LocalLockController(ChannelLocalLock());
  late final lockNavigation = LockNavigationObserver(localLock);
  void _lockChanged() {
    navigationHistory.blocked = !localLock.ready || localLock.locked;
  }

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
      onLogout: () => controller.signOut(),
      passkeys: passkeys,
      googleAvailability: () => widget.google.available,
      creation: passkeys,
      headerRequest: androidHeaderRequest(apiOrigin),
      deviceLabel: androidDeviceLabel,
      settingsEnabled: true,
      realtimeConnector: androidRealtimeConnector(apiOrigin),
    );
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
    switch (controller.phase) {
      case NativeSessionPhase.signedIn:
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
    _importForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      bridge.realtimeSetForeground(true);
    } else if (state != AppLifecycleState.inactive) {
      bridge.realtimeSetForeground(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_maybeRecover);
    startup.dispose();
    devices.dispose();
    bridge.disposeRealtime();
    _importPicker.cancel();
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
          signedInBuilder: (context) => NativeNavigation(
            history: navigationHistory,
            builder: (context, route, navigate) {
              final session = controller.session;
              final identityEpoch = controller.identityEpoch;
              final lockGeneration = localLock.lockGeneration;
              Future<bool> importCurrent() async =>
                  mounted &&
                  _importForeground &&
                  controller.identityEpoch == identityEpoch &&
                  controller.session?.deviceId == session?.deviceId &&
                  controller.phase == NativeSessionPhase.signedIn &&
                  localLock.ready &&
                  !localLock.locked &&
                  localLock.lockGeneration == lockGeneration;
              final coordinatorKey = (identityEpoch, lockGeneration);
              if (_importEnabled &&
                  session != null &&
                  _importCoordinatorKey != coordinatorKey) {
                _importCoordinatorKey = coordinatorKey;
                _importCoordinator = OwnerBoundImportCoordinator(
                  deviceId: session.deviceId,
                  current: importCurrent,
                  readSession: () async {
                    final r = await bridge.read('/v1/manage/session');
                    return (status: r.status, body: r.body);
                  },
                  post: bridge.transferPost,
                  passkeys: passkeys,
                  journal: ChannelImportJournal(),
                );
              }
              final page = BrowserAccountPage(
                bridge: bridge,
                importSaver: _importEnabled ? _importCoordinator : null,
                transferPageBuilder: !_importEnabled || session == null
                    ? null
                    : (existing, refresh) => VerifiedImportFlow(
                        key: ValueKey((identityEpoch, lockGeneration)),
                        deviceId: session.deviceId,
                        coordinator: _importCoordinator,
                        existing: existing,
                        onSaved: refresh,
                        readFile: () => guardedImportFile(
                          current: importCurrent,
                          pick: _importPicker.pick,
                        ),
                        current: importCurrent,
                        readSession: () async {
                          final r = await bridge.read('/v1/manage/session');
                          return (status: r.status, body: r.body);
                        },
                        post: bridge.transferPost,
                        passkeys: passkeys,
                        journal: ChannelImportJournal(),
                      ),
                localSecuritySetting: LocalLockSetting(controller: localLock),
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
