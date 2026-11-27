import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';

import 'package:flutter/services.dart';

import 'dart:convert';
import 'dart:math';

import 'native_local_lock_recovery.dart';

abstract interface class LocalLockPlatform {
  Future<bool> enabled();
  Future<bool> verify();
  Future<void> setEnabled(bool value);
}

class ChannelLocalLock implements LocalLockPlatform {
  static const channel = MethodChannel('app.otpanda/app-lock');
  @override
  Future<bool> enabled() async =>
      await channel.invokeMethod<bool>('enabled') ?? false;
  @override
  Future<bool> verify() async =>
      await channel.invokeMethod<bool>('verify') == true;
  @override
  Future<void> setEnabled(bool value) =>
      channel.invokeMethod('setEnabled', {'enabled': value});
}

class LocalLockController extends ChangeNotifier {
  LocalLockController(this.platform);
  final LocalLockPlatform platform;
  NativeLocalLockRecovery? recovery;
  String lockGeneration = base64UrlEncode(
    List<int>.generate(32, (_) => Random.secure().nextInt(256)),
  ).replaceAll('=', '');
  void _rotate() {
    lockGeneration = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
  }

  Future<void> recover({required bool disable}) async {
    if (busy || !enabled || !locked || recovery == null) return;
    busy = true;
    error = null;
    _emit();
    final generation = lockGeneration;
    try {
      final outcome = await recovery!.verify(
        disable ? 'local-lock-disable' : 'local-unlock-once',
      );
      if (_disposed || generation != lockGeneration) return;
      if (outcome != (disable ? 'DISABLED' : 'UNLOCK_GRANTED')) {
        error = switch (outcome) {
          'ABORTED' || 'USER_CANCELLED' => null,
          'UNLOCK_EXPIRED' => 'Passkey unlock expired. Verify again to unlock.',
          'PASSKEY_UNAVAILABLE' => 'Passkey verification is unavailable on this device. App lock remains on.',
          'UNSUPPORTED_OS' => 'Passkey app-lock recovery requires Android 11 or later. App lock remains on.',
          'NETWORK_UNAVAILABLE' => 'No connection. App lock remains on.',
          'OUTCOME_UNKNOWN' =>
            'Could not confirm. App lock remains on. Try again.',
          'UNAUTHORIZED' => 'Session verification is unavailable. App lock remains on. Try again.',
          _ => 'Passkey verification did not complete. App lock remains on.',
        };
        return;
      }
      if (disable) enabled = false;
      if (foreground) {
        locked = false;
      } else {
        _verifiedAwaitingResume = true;
        _verifiedAt = _elapsed.elapsedMilliseconds;
      }
      _rotate();
    } catch (_) {
      error = 'Passkey verification did not complete. App lock remains on.';
    } finally {
      try {
        final saved = await platform.enabled();
        if (!_disposed) {
          enabled = saved;
          if (!saved) {
            locked = false;
            _verifiedAwaitingResume = false;
            error = null;
          }
        }
      } catch (_) {
        if (!_disposed) {
          locked = true;
          error = 'Device lock state could not be confirmed. Try again.';
        }
      }
      busy = false;
      _emit();
    }
  }

  void sessionChanged() {
    recovery?.cancel().catchError((_) {});
    _rotate();
    _verifiedAwaitingResume = false;
    if (enabled) locked = true;
    _emit();
  }

  bool ready = false, enabled = false, locked = true, busy = false;
  String? error;
  bool foreground = true;
  bool _disposed = false, _verifiedAwaitingResume = false;
  final _elapsed = Stopwatch()..start();
  int _verifiedAt = 0;
  @override
  void dispose() {
    _disposed = true;
    recovery?.cancel().catchError((_) {});
    super.dispose();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void resume() {
    foreground = true;
    if (_verifiedAwaitingResume &&
        _elapsed.elapsedMilliseconds - _verifiedAt <= 5000) {
      _verifiedAwaitingResume = false;
      locked = false;
      error = null;
      _emit();
    }
  }

  Future<void> load() async {
    try {
      enabled = await platform.enabled();
      locked = enabled;
      ready = true;
      error = null;
    } catch (_) {
      error = 'Device lock could not be read.';
    }
    _emit();
  }

  void background() {
    foreground = false;
    _verifiedAwaitingResume = false;
    if (enabled && !locked) {
      locked = true;
      _rotate();
      _emit();
    }
  }

  Future<void> unlock() async {
    if (busy) return;
    busy = true;
    error = null;
    _emit();
    try {
      if (await platform.verify()) {
        if (_disposed) return;
        error = null;
        if (foreground) {
          locked = false;
        } else {
          _verifiedAwaitingResume = true;
          _verifiedAt = _elapsed.elapsedMilliseconds;
        }
      }
    } catch (_) {
      error = 'Not unlocked. Try device unlock again.';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> change(bool value) async {
    if (busy) return;
    busy = true;
    error = null;
    _emit();
    try {
      if (await platform.verify()) {
        if (_disposed) return;
        await platform.setEnabled(value);
        if (_disposed) return;
        enabled = value;
        locked = enabled && !foreground;
        _verifiedAwaitingResume = enabled && !foreground;
        _verifiedAt = _elapsed.elapsedMilliseconds;
        error = null;
        _rotate();
      }
    } catch (_) {
      error = 'Device lock was not changed. A secure screen lock is required.';
    } finally {
      busy = false;
      _emit();
    }
  }
}

class NativeAppLock extends StatefulWidget {
  const NativeAppLock({
    super.key,
    required this.controller,
    required this.child,
  });
  final LocalLockController controller;
  final Widget child;
  @override
  State<NativeAppLock> createState() => _NativeAppLockState();
}

class _NativeAppLockState extends State<NativeAppLock>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      widget.controller.background();
    } else {
      widget.controller.resume();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final hide = !c.ready || c.locked;
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Offstage(offstage: hide, child: widget.child),
            if (hide)
              Positioned.fill(
                child: Material(
                  color: context.pal.field,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_outline, size: 44),
                        const SizedBox(height: 16),
                        const Text('OTPanda is locked'),
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'If your secure screen lock was removed or device unlock is unavailable, verify a passkey to unlock once or turn app lock off.',
                          ),
                        ),
                        if (c.recovery != null) ...[
                          TextButton(
                            onPressed: c.busy
                                ? null
                                : () => c.recover(disable: false),
                            child: const Text('Unlock once with a passkey'),
                          ),
                          TextButton(
                            onPressed: c.busy
                                ? null
                                : () => c.recover(disable: true),
                            child: const Text(
                              'Turn off app lock with a passkey',
                            ),
                          ),
                        ],
                        if (c.error != null) Text(c.error!),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: c.busy
                              ? null
                              : () => c.ready ? c.unlock() : c.load(),
                          child: Text(
                            c.busy
                                ? 'Checking...'
                                : c.ready
                                ? 'Device unlock'
                                : 'Retry',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class LocalLockSetting extends StatelessWidget {
  const LocalLockSetting({super.key, required this.controller});
  final LocalLockController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      children: [
        SwitchListTile(
          title: const Text('Device unlock'),
          subtitle: const Text(
            'Require biometrics or screen lock when opening or returning to OTPanda. Hide app-switcher contents and block screenshots while enabled.',
          ),
          value: controller.enabled,
          onChanged: controller.ready && !controller.busy
              ? controller.change
              : null,
        ),
        if (controller.error != null) Text(controller.error!),
      ],
    ),
  );
}

/// Registers a veto on every actual Navigator route, including dialogs. The
/// visual curtain lives above Navigator and cannot own a PopScope itself.
/// This app uses one root Navigator. Any future nested Navigator must also
/// install a lock observer before it can hold sensitive routes.
class LockNavigationObserver extends NavigatorObserver {
  LockNavigationObserver(this.controller) {
    controller.addListener(_changed);
  }
  final LocalLockController controller;
  final entries = <Route<dynamic>, _LockPopEntry>{};
  bool get blocked => !controller.ready || controller.locked;
  void _changed() {
    for (final e in entries.values) {
      e.canPopNotifier.value = !blocked;
    }
  }

  void _add(Route<dynamic> route) {
    if (route is ModalRoute<dynamic>) {
      final e = _LockPopEntry(!blocked);
      entries[route] = e;
      route.registerPopEntry(e);
    }
  }

  void _remove(Route<dynamic> route) {
    final e = entries.remove(route);
    if (e != null) {
      if (route is ModalRoute<dynamic>) route.unregisterPopEntry(e);
      e.canPopNotifier.dispose();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _remove(oldRoute);
    if (newRoute != null) _add(newRoute);
  }

  void dispose() {
    controller.removeListener(_changed);
    for (final r in entries.keys.toList()) {
      _remove(r);
    }
  }
}

class _LockPopEntry extends PopEntry<dynamic> {
  _LockPopEntry(bool allowed) : canPopNotifier = ValueNotifier(allowed);
  @override
  final ValueNotifier<bool> canPopNotifier;
}
