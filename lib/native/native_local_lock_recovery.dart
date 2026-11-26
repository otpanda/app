import 'package:flutter/services.dart';

abstract interface class LocalRecoveryPlatform {
  Future<String> start(String intent, String bearer);
  Future<void> cancel();
  Future<bool> consumeUnlock();
}

class ChannelLocalRecovery implements LocalRecoveryPlatform {
  static const channel = MethodChannel('app.otpanda/lock-recovery');
  @override
  Future<String> start(String intent, String bearer) async =>
      await channel.invokeMethod<String>('start', {
        'intent': intent,
        'bearer': bearer,
      }) ??
      'UNAVAILABLE';
  @override
  Future<void> cancel() => channel.invokeMethod('cancel');
  @override
  Future<bool> consumeUnlock() async =>
      await channel.invokeMethod<bool>('consumeUnlock') == true;
}

/// Native owns the passkey ceremony, HTTPS finish and persistent lock effect.
/// A Dart boolean never authorizes disabling the native lock flag.
class NativeLocalLockRecovery {
  NativeLocalLockRecovery({required this.platform, required this.bearer});
  final LocalRecoveryPlatform platform;
  final Future<String?> Function() bearer;
  int _generation = 0;

  Future<String> verify(String intent) async {
    final generation = _generation;
    final token = await bearer();
    if (generation != _generation) return 'ABORTED';
    if (token == null) return 'UNAUTHORIZED';
    final outcome = await platform.start(intent, token);
    if (generation != _generation) return 'ABORTED';
    if (outcome == 'UNLOCK_GRANTED' && !await platform.consumeUnlock()) {
      return 'ABORTED';
    }
    return generation == _generation ? outcome : 'ABORTED';
  }

  Future<void> cancel() async {
    _generation++;
    await platform.cancel();
  }
}
