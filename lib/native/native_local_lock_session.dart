/// A native device id is server-bound to one owner and security generation.
/// Access tokens rotate within that device session and are not lock boundaries.
class NativeLocalLockSessionBoundary {
  String? _deviceId;

  bool update(String? deviceId, {bool signedOut = false}) {
    if (deviceId == null && !signedOut) return false;
    if (deviceId == _deviceId) return false;
    _deviceId = deviceId;
    return true;
  }
}
