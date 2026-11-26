import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

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
  bool ready = false, enabled = false, locked = true, busy = false;
  String? error;
  bool foreground = true;
  bool _disposed = false, _verifiedAwaitingResume = false;
  final _elapsed = Stopwatch()..start();
  int _verifiedAt = 0;
  @override
  void dispose() {
    _disposed = true;
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
                child: PopScope(
                  canPop: false,
                  child: Material(
                    color: const Color(0xfff3f7f5),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.lock_outline, size: 44),
                          const SizedBox(height: 16),
                          const Text('OTPanda is locked'),
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
