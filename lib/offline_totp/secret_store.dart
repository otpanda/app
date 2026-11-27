import 'dart:typed_data';

/// Why an OS key store refused. Mapped by each platform adapter. Never carries
/// a value, a platform message, or account data.
enum SecretStoreError {
  /// No keyring, Keychain or DPAPI can be used at all (for example Linux
  /// without a Secret Service, or a plugin/channel failure). Not a recovery
  /// signal: nothing may be purged or re-enrolled because of it.
  unavailable,

  /// The store exists but is locked or needs user interaction. Retry after
  /// unlock. Never a fallback to plaintext.
  locked,

  /// The OS refused this app (denied prompt, missing entitlement, changed code
  /// signature). Retrying without user action will not help.
  denied,

  /// A value was found but cannot be read as the value that was stored
  /// (damaged, undecryptable, wrong shape). Distinct from absence: the caller
  /// must not treat the key as missing, recreate it, or purge anything.
  corrupt,
}

final class SecretStoreException implements Exception {
  const SecretStoreException(this.error, {this.outcomeUnknown = false});
  final SecretStoreError error;

  /// True only for a mutation that may or may not have been applied before the
  /// failure (crash, timeout, platform error after the call started). The
  /// caller must read back and reconcile before trusting either state.
  final bool outcomeUnknown;

  @override
  String toString() =>
      'SecretStoreException(${error.name}, unknown: $outcomeUnknown)';
}

/// Holds only small non-derivable secrets, namely the wrapping key that seals
/// the app's own encrypted state. It is deliberately not a general key-value
/// store and never holds seeds, account data or metadata. The authoritative
/// state lives outside it, sealed under the key stored here.
///
/// Contract every adapter and fake must keep:
/// - [read] returns null only when the name is definitely absent. If the store
///   cannot answer, or the value is damaged, it throws; absence is never
///   inferred from an error or from an empty result.
/// - [createIfAbsent] is create-only. It never overwrites. It returns the
///   value that is stored afterwards (the caller's or an existing winner), so
///   a lost key is never silently replaced by a new one that would orphan
///   sealed data. On failure it throws; when [SecretStoreException.outcomeUnknown]
///   is true the caller must [read] before doing anything else.
/// - [delete] of an absent name succeeds. A failed delete throws; when
///   outcomeUnknown the caller treats the key as possibly gone and possibly
///   present, and reads back.
/// - No method logs, copies to the clipboard or falls back to plaintext
///   storage. Names are non-secret.
/// - Adapters must not rely on the plugin's own absence or error codes without
///   verification. No adapter may delete damaged state during a read.
///   A missing key or canary never by itself proves a fresh installation:
///   either may have been deleted along with the encrypted state. The caller
///   reconciles durable installation/account state before creating a key.
abstract interface class SecretStore {
  /// Name of the backing mechanism for diagnostics, for example
  /// `secret-service`. Not a security claim.
  String get kind;

  Future<Uint8List?> read(String name);
  Future<Uint8List> createIfAbsent(String name, Uint8List candidate);
  Future<void> delete(String name);
}

/// Test double with failure injection. Not for production: it keeps bytes in
/// process memory.
final class FakeSecretStore implements SecretStore {
  FakeSecretStore({this.kind = 'fake'});

  @override
  final String kind;

  final Map<String, Uint8List> _values = {};

  /// When set, every call throws this error without changing anything.
  SecretStoreError? failAll;

  /// Names whose stored value reads as damaged ([SecretStoreError.corrupt]).
  final Set<String> corruptNames = {};

  /// Next [createIfAbsent] throws. If [applyFailedMutation] is true the
  /// mutation was applied before the error (an unknown outcome that landed).
  SecretStoreError? failNextCreate;
  SecretStoreError? failNextDelete;
  bool applyFailedMutation = false;

  /// Marks the failure as outcomeUnknown; otherwise the mutation is known not
  /// to have happened.
  bool failureOutcomeUnknown = false;

  int creates = 0, deletes = 0;

  Set<String> get names => _values.keys.toSet();

  @override
  Future<Uint8List?> read(String name) async {
    final f = failAll;
    if (f != null) throw SecretStoreException(f);
    if (corruptNames.contains(name)) {
      throw const SecretStoreException(SecretStoreError.corrupt);
    }
    final v = _values[name];
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<Uint8List> createIfAbsent(String name, Uint8List candidate) async {
    final f = failAll ?? failNextCreate;
    failNextCreate = null;
    if (f != null) {
      if (applyFailedMutation &&
          failureOutcomeUnknown &&
          !corruptNames.contains(name) &&
          !_values.containsKey(name)) {
        _values[name] = Uint8List.fromList(candidate);
      }
      throw SecretStoreException(f, outcomeUnknown: failureOutcomeUnknown);
    }
    if (corruptNames.contains(name)) {
      throw const SecretStoreException(SecretStoreError.corrupt);
    }
    final existing = _values[name];
    if (existing != null) return Uint8List.fromList(existing);
    _values[name] = Uint8List.fromList(candidate);
    creates++;
    return Uint8List.fromList(candidate);
  }

  @override
  Future<void> delete(String name) async {
    final f = failAll ?? failNextDelete;
    failNextDelete = null;
    if (f != null) {
      if (applyFailedMutation && failureOutcomeUnknown) _values.remove(name);
      throw SecretStoreException(f, outcomeUnknown: failureOutcomeUnknown);
    }
    _values.remove(name);
    corruptNames.remove(name);
    deletes++;
  }
}

/// Maps a [SecretStoreError] to the custody contract's error names so desktop
/// adapters report the same honest states as Android: locked -> locked,
/// corrupt -> tamper (a damaged key is not a missing one), unavailable and
/// denied -> unavailable. Nothing here authorizes purge or re-enrollment.
String custodyErrorNameFor(SecretStoreError e) => switch (e) {
  SecretStoreError.locked => 'locked',
  SecretStoreError.corrupt => 'tamper',
  SecretStoreError.unavailable => 'unavailable',
  SecretStoreError.denied => 'unavailable',
};
