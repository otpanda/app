/// Unlinks Google as a sign-in method. The web bridge does it through the
/// recovery controls' passkey step-up (kind google-unlink, no target). A
/// bridge that cannot do this does not implement it and the UI shows no
/// Disconnect.
abstract interface class GoogleLinkBridge {
  bool get googleDisconnectAvailable;
  Future<void> disconnectGoogle();
}
