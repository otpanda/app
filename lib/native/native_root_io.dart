import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../native_browser_fallback.dart';
import '../browser_account_page.dart';
import 'android_adapters.dart';
import 'native_assignment.dart';
import 'native_bridge.dart';
import 'native_app.dart';
import 'native_app_lock.dart';
import 'native_navigation.dart';
import 'native_auth.dart';
import 'native_device_proof.dart';
import 'native_device_startup.dart';
import 'native_devices.dart';
import 'native_add_device.dart';
import 'native_handoff.dart';
import 'native_passkey.dart';
import 'native_session.dart';

/// Build-time switches. Native sign-in stays off (the honest browser-launcher
/// page) until BOTH the Pages native-intent bridge and the App Link
/// association exist; enable with --dart-define=NATIVE_SIGNIN=true.
const bool nativeSignInEnabled = bool.fromEnvironment('NATIVE_SIGNIN');

/// Qualified independently of NATIVE_AUTH_ENABLED (enrolled-device flows,
/// STEP_UP). Each is off until its own acceptance passes on a device:
/// entry rename/account edit needs the server's native entry routes; settings
/// (recovery, security, passkey labels, Google connect) needs the settings
/// contract deployed. Turning one on never turns on step-up.
const bool nativeEntryEditEnabled = bool.fromEnvironment(
  'NATIVE_ENTRY_EDIT_ENABLED',
);

/// Needs the API's /v1/manage/entry/domains routes deployed.
const bool nativeEntryDomainsEnabled = bool.fromEnvironment(
  'NATIVE_ENTRY_DOMAINS_ENABLED',
);
const bool nativeSettingsEnabled = bool.fromEnvironment(
  'NATIVE_SETTINGS_ENABLED',
);
const String apiOrigin = String.fromEnvironment(
  'OTPANDA_API_ORIGIN',
  defaultValue: 'https://otpanda-api.abrahammurciano.workers.dev',
);

Widget buildNativeRoot() {
  if (!nativeSignInEnabled) return const NativeBrowserFallbackApp();
  final google = AndroidGoogleSource();
  return _Boot(google: google);
}

class _Boot extends StatefulWidget {
  const _Boot({required this.google});
  final AndroidGoogleSource google;
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with WidgetsBindingObserver {
  late final NativeSessionController controller;
  late final NativeSessionBridge bridge;
  final passkeys = AndroidPasskeySource();
  bool ready = false;
  final localLock = LocalLockController(ChannelLocalLock());
  final navigationHistory = NativeNavigationHistory();
  late final NativeStartupRecovery startup;
  late final NativeDevicesService devices;
  late final BearerRequest _bearer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = NativeSessionController(
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
    _bearer = androidBearerRequest(apiOrigin);
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
      settingsEnabled: nativeSettingsEnabled,
      realtimeConnector: androidRealtimeConnector(apiOrigin),
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
  void _maybeRecover() {
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
    navigationHistory.dispose();
    localLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ready
      ? NativeApp(
          appWrapper: (context, child) =>
              NativeAppLock(controller: localLock, child: child),
          controller: controller,
          googleAvailable: widget.google.available,
          version: const String.fromEnvironment('APP_VERSION'),
          authBridge: bridge,
          signedInBuilder: (context) => NativeNavigation(
            history: navigationHistory,
            builder: (context, route, navigate) {
              final page = BrowserAccountPage(
                bridge: bridge,
                localSecuritySetting: LocalLockSetting(controller: localLock),
                navigation: route,
                onNavigate: navigate,
                accountOnly: true,
                signOutEnabled: true,
                workspaceEnabled: true,
                // Off with NATIVE_AUTH_ENABLED: needs the enrolled device key.
                assignmentEnabled: nativeAuthEnabled,
                // Own switch: needs the server's native entry routes.
                entryEditEnabled: nativeEntryEditEnabled,
                entryDomainsEnabled: nativeEntryDomainsEnabled,
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
