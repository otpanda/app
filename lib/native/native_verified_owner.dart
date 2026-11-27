/// A server-verified owner belongs only to the exact session that was checked.
/// A renewal or replacement must be verified again, even for the same device.
final class NativeVerifiedOwner {
  Object? _session;
  String? _owner;

  String? ownerFor(Object? session) =>
      session != null && identical(session, _session) ? _owner : null;

  void bind(Object session, String owner) {
    _session = session;
    _owner = owner;
  }

  void clear() {
    _session = null;
    _owner = null;
  }
}

/// A known different online account must not be labelled as the cold account.
/// Null means cold start has no new account claim, so durable admission decides.
final class NativeLocalOwnerDisplay {
  String? _knownOwner;
  void verified(String owner) => _knownOwner = owner;
  bool allows(String owner) => _knownOwner == null || _knownOwner == owner;
}
