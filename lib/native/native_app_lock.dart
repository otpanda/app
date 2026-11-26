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
  Future<void> load() async {
    try {
      enabled = await platform.enabled();
      locked = enabled;
      ready = true;
    } catch (_) {
      error = 'Device lock could not be read.';
    }
    notifyListeners();
  }

  void background() {
    foreground = false;
    if (enabled && !locked) {
      locked = true;
      notifyListeners();
    }
  }

  Future<void> unlock() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (await platform.verify() && foreground) locked = false;
    } catch (_) {
      error = 'Not unlocked. Try device unlock again.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> change(bool value) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (await platform.verify()) {
        await platform.setEnabled(value);
        enabled = value;
        locked = enabled && !foreground;
      }
    } catch (_) {
      error = 'Device lock was not changed. A secure screen lock is required.';
    } finally {
      busy = false;
      notifyListeners();
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
      widget.controller.foreground = true;
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
