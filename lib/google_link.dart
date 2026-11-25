/// Unlinks Google as a sign-in method. The web bridge does it through the
/// recovery controls' passkey step-up (kind google-unlink, no target). A
/// bridge that cannot do this does not implement it and the UI shows no
/// Disconnect.
abstract interface class GoogleLinkBridge {
  bool get googleDisconnectAvailable;
  Future<void> disconnectGoogle();
}

/// Connects Google to the signed-in account without leaving the session. The
/// web bridge asks for a one-time ticket, sends the browser to Google and
/// returns to the same settings page. A bridge that cannot do this does not
/// implement it and Connect falls back to the ordinary sign-in entry.
abstract interface class GoogleConnectBridge {
  bool get googleConnectAvailable;

  /// Empty when the browser is leaving for Google, otherwise a reason code:
  /// already_linked, no_passkey, retry, signin or unavailable.
  Future<String> connectGoogle();

  /// One-time result of a connect that just returned: connected, restart,
  /// mismatch, cancelled, or empty.
  String takeGoogleLinkResult();
}
