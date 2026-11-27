import 'dart:convert';
import 'dart:typed_data';

import 'otp_account.dart';

/// What a platform adapter can actually promise. Never claim more than the
/// adapter measured: a fake or software store reports [osEncrypted] or
/// [unavailable], not hardware.
enum CustodyProtection {
  /// The HMAC key never leaves hardware (Android Keystore HMAC handle).
  hardwareHmac,

  /// A hardware key wraps the seed, but the seed is in process memory while a
  /// code is computed (for example TPM or Secure Enclave wrapping).
  hardwareWrapped,

  /// An OS-held key (DPAPI, keychain, Secret Service) encrypts the seed at
  /// rest; the seed is in process memory while a code is computed.
  osEncrypted,

  /// No custody is possible on this device right now. Nothing is stored.
  unavailable,
}

final class CustodyCapability {
  const CustodyCapability(this.protection, this.reason);

  final CustodyProtection protection;

  /// Human-readable cause when [protection] is [CustodyProtection.unavailable]
  /// (for example no Secret Service); null otherwise. Never contains seed or
  /// account data.
  final String? reason;
}

enum CustodyError {
  /// No usable store (no keyring, no hardware, platform refused).
  unavailable,

  /// The store exists but is locked; nothing was read or written.
  locked,

  /// The wrapping key is gone, so stored records cannot be opened.
  missingKey,

  /// No record for that owner and entry.
  notFound,

  /// The stored record was altered, swapped or does not match its metadata.
  tamper,

  /// A provision whose seed version is not newer than the stored one, or a
  /// generate asked for a version other than the stored one.
  versionConflict,

  /// A provision or snapshot from an epoch the owner has since opted out of.
  staleEpoch,

  /// The owner opted out, or the entry was deleted or tombstoned at or above
  /// this version. Logically final even if the physical delete is pending.
  denied,

  /// A snapshot that is not newer than the last one applied for the owner.
  staleSnapshot,

  /// A snapshot that contradicts itself or has invalid fields; nothing applied.
  invalidSnapshot,

  /// Bad identifier, parameter or seed.
  invalidInput,

  /// A provision or snapshot carries an epoch above the device's current one.
  /// Only local lifecycle transitions ([NativeSeedCustody.clearOwner],
  /// [NativeSeedCustody.enableOwner]) advance the epoch; a server response
  /// never can, so it cannot erase version history or other entries' custody.
  epochMismatch,

  /// The owner is opted out (persisted). Only [NativeSeedCustody.enableOwner]
  /// with an epoch at or above the current one lifts it; a server response
  /// carrying a higher epoch cannot.
  disabled,

  /// The durable non-secret metadata (epoch, disabled flag, version floors,
  /// snapshot order, pending purges) cannot be read or written. Adapters must
  /// fail closed: the operation changes nothing and reports this. A caller
  /// that gets it from clearOwner must treat the owner as denied itself and
  /// retry; generate also fails with it rather than risk serving a denied
  /// record.
  metadataUnavailable,
}

final class CustodyException implements Exception {
  const CustodyException(this.error);

  final CustodyError error;

  @override
  String toString() => 'CustodyException(${error.name})';
}

/// Largest integer that compiled JavaScript represents exactly.
const custodyMaxSafeInt = 9007199254740991;

/// One authenticated server statement for an owner, used by [reconcile].
final class CustodySnapshot {
  const CustodySnapshot({
    required this.epoch,
    required this.revision,
    required this.complete,
    required this.versions,
    this.tombstones = const {},
    this.preserve = const {},
  });

  /// The owner epoch this snapshot was issued under (see [clearOwner]).
  final int epoch;

  /// Monotonic per owner and epoch. A lower revision is refused as stale. An
  /// equal revision is replayed only when the durably recorded full statement
  /// (complete, versions, tombstones, preserve) is identical, else it is stale.
  final int revision;

  /// True only when [versions] plus [preserve] list every present entry the device
  /// may hold for the owner. A partial snapshot never causes deletion of unlisted entries.
  final bool complete;

  /// entryId to the current authorised seed version.
  final Map<String, int> versions;

  /// entryId to the version at or below which the entry is deleted for good.
  /// A listed version must be greater than its tombstone.
  final Map<String, int> tombstones;

  /// Entries the server lists as unsupported or metadata-pending. A complete
  /// snapshot never removes them for being absent from [versions]. A tombstone
  /// still does. They must not appear in [versions].
  final Set<String> preserve;
}

final class ReconcileResult {
  const ReconcileResult({
    required this.removed,
    required this.needsProvision,
    required this.pendingPurge,
    this.superseded = const [],
  });

  /// Entries whose local record is older than the authoritative snapshot
  /// version (a rotation). The old record is logically denied at once, so no
  /// superseded code is produced while the replacement is still pending; they
  /// also appear in [needsProvision]. The rotation floor is the old version,
  /// so the wanted newer version can still be provisioned.
  final List<String> superseded;

  /// Entries logically removed (tombstoned, or unlisted in a complete
  /// snapshot). They can no longer generate or be re-provisioned at or below
  /// that version, even if the physical delete is still pending.
  final List<String> removed;

  /// Entries absent locally or older than the snapshot, and not blocked by a
  /// delete: the caller must provision a newer seed version.
  final List<String> needsProvision;

  /// Entries whose physical delete failed (store locked or unavailable). Retry
  /// with [NativeSeedCustody.purgePending].
  final List<String> pendingPurge;
}

/// Outcome of [NativeSeedCustody.clearOwner]. [denied] is always true once the
/// call returns: generation and provisioning for the old epoch are refused
/// immediately. [purged] is false when the physical delete is still pending.
final class ClearOwnerResult {
  const ClearOwnerResult({required this.purged});
  final bool denied = true;
  final bool purged;
}

/// App-facing custody boundary for offline TOTP on native clients.
///
/// There is deliberately no method that returns seed bytes. Adapters that keep
/// the seed in memory to compute a code (desktop) do so internally and return
/// only the code. A seed export interface is a separate, ungrounded feature
/// that needs a fresh strong export grant and is not part of this contract.
///
/// Remote revocation is not instant: a device that is offline keeps its
/// records until it reconnects and reconciles or is cleared.
/// Durable local opt-out state only. Never restores sync authorization.
final class CustodyOwnerState {
  const CustodyOwnerState({required this.epoch, required this.enabled});
  final int epoch;
  final bool enabled;
}

/// Logical durable metadata only. Generation may still fail locked/missing/tamper.
final class CustodyCatalogEntry {
  const CustodyCatalogEntry({
    required this.entryId,
    required this.seedVersion,
    required this.epoch,
    required this.algorithm,
    required this.digits,
    required this.period,
    required this.protection,
    required this.floor,
    required this.minAcceptedVersion,
  });
  final String entryId, protection;
  final int seedVersion, epoch, digits, period, floor, minAcceptedVersion;
  final OtpAlgorithm algorithm;
}

final class CustodyCatalog {
  const CustodyCatalog({
    required this.epoch,
    required this.enabled,
    required this.entries,
    required this.pendingPurge,
  });
  final int epoch;
  final bool enabled;
  final List<CustodyCatalogEntry> entries;
  final List<String> pendingPurge;
}

final class PurgeOwnerResult {
  const PurgeOwnerResult({required this.purged, required this.epoch});
  final bool purged;
  final int epoch;
}

abstract interface class NativeSeedCustody {
  /// Read-only. A never-seen owner starts at epoch 0, enabled by default.
  /// Unreadable metadata fails closed; it is never treated as a new owner.
  Future<CustodyOwnerState> readOwnerState(String ownerId);

  Future<CustodyCapability> capability();
  Future<CustodyCatalog> readCatalog(String ownerId);

  /// Ordinary lifecycle purge, not persistent opt-out. Use returned epoch.
  /// A caller epoch above native truth fails epochMismatch without mutation.
  Future<PurgeOwnerResult> purgeOwner(String ownerId, {required int epoch});

  /// Stores [seed] for the owner and entry. [seedVersion] must be greater than
  /// any stored version for that entry, so an old response cannot overwrite a
  /// newer seed. [epoch] must be at least the owner's current epoch (see
  /// [clearOwner]); the epoch must equal the owner's current local epoch exactly (lower:
  /// [CustodyError.staleEpoch], higher: [CustodyError.epochMismatch]). A
  /// disabled owner throws [CustodyError.disabled]. The caller zeroes its own copy of [seed] when done.
  Future<void> provision({
    required String ownerId,
    required String entryId,
    required int seedVersion,
    required OtpAlgorithm algorithm,
    required int digits,
    required int period,
    required Uint8List seed,
    required int epoch,
  });

  /// Returns the code for [unixSeconds]. Fails closed (never a stale or default
  /// code) when the record is missing, tampered, a different version, or the
  /// store is unavailable, locked or missing its key.
  Future<String> generate({
    required String ownerId,
    required String entryId,
    required int seedVersion,
    required int unixSeconds,
  });

  /// Deletes the entry up to [seedVersion], which is required: the deletion
  /// floor is recorded first, even when no record exists, so an in-flight
  /// provision at or below it cannot resurrect the entry; a newer version can
  /// still be provisioned. A stored record newer than [seedVersion] is left
  /// alone. A matching record is logically denied at once, then deleted
  /// physically. Throws only for invalid input; a failed physical delete stays
  /// pending for [purgePending].
  Future<void> delete(
    String ownerId,
    String entryId, {
    required int seedVersion,
  });

  /// Opt-out, sign-out or account removal for records up to [epoch]. Persists
  /// first: the owner's epoch becomes [epoch] + 1 and the owner is marked
  /// disabled, so every later generate for older records, and every provision
  /// or snapshot until [enableOwner], is refused at once, even when the store
  /// is locked. Then deletes records with epoch <= [epoch] only; records from
  /// a newer epoch are never denied or deleted by an older clear, and an
  /// older clear never lowers the epoch or changes the disabled flag. A locked
  /// or unavailable store leaves the purge pending (see
  /// [ClearOwnerResult.purged]); there is no plaintext fallback. Needs durable
  /// metadata (throws [CustodyError.metadataUnavailable] and changes nothing).
  /// A caller epoch above native truth fails epochMismatch without mutation.
  Future<ClearOwnerResult> clearOwner(String ownerId, {required int epoch});

  /// Explicit re-enable after [clearOwner]. [epoch] must be at least the
  /// owner's current epoch (else [CustodyError.staleEpoch]); it becomes the
  /// current epoch and clears the disabled flag. Version floors are
  /// epoch-scoped, so they restart when the epoch rises. A provision or
  /// snapshot cannot do this implicitly.
  Future<void> enableOwner(String ownerId, {required int epoch});

  /// Retries every pending physical delete. Returns the owners and entries
  /// still pending, as `owner/entry` identifiers without seed data.
  Future<List<String>> purgePending();

  /// Applies an authenticated [CustodySnapshot] for [ownerId]. The snapshot is
  /// validated whole before anything changes. Never needs the store to be
  /// unlocked: logical removals are recorded, physical deletes may stay pending.
  Future<ReconcileResult> reconcile(String ownerId, CustodySnapshot snapshot);
}

final _badId = RegExp(r'[\u0000-\u001f\u007f]');

/// True for a non-empty identifier of at most 128 characters without control
/// characters.
bool validCustodyId(String s) =>
    s.isNotEmpty && s.length <= 128 && !_badId.hasMatch(s);

/// Throws [CustodyError.invalidInput] for anything an adapter must not store.
void validateCustodyInput({
  required String ownerId,
  required String entryId,
  required int seedVersion,
  required int digits,
  required int period,
  required Uint8List seed,
  int epoch = 0,
}) {
  if (!validCustodyId(ownerId) ||
      !validCustodyId(entryId) ||
      seedVersion < 1 ||
      seedVersion > custodyMaxSafeInt ||
      epoch < 0 ||
      epoch >= custodyMaxSafeInt ||
      digits < 6 ||
      digits > 8 ||
      period < 1 ||
      period > 86400 ||
      seed.length < OtpAccount.minSecretBytes ||
      seed.length > OtpAccount.maxSecretBytes) {
    throw const CustodyException(CustodyError.invalidInput);
  }
}

/// Authenticated-data bytes an adapter must bind to every stored record, so a
/// record cannot be moved to another owner, entry, version, epoch or parameter
/// set.
/// Fields are length-prefixed, so no field boundary is ambiguous.
Uint8List custodyAad({
  required String ownerId,
  required String entryId,
  required int seedVersion,
  required OtpAlgorithm algorithm,
  required int digits,
  required int period,
  required int epoch,
}) {
  final out = BytesBuilder();
  void field(List<int> b) {
    out.add((ByteData(4)..setUint32(0, b.length)).buffer.asUint8List());
    out.add(b);
  }

  field(utf8.encode('otpanda-native-seed-record-v1'));
  field(utf8.encode(ownerId));
  field(utf8.encode(entryId));
  field(utf8.encode('$seedVersion'));
  field(utf8.encode(algorithm.name));
  field(utf8.encode('$digits'));
  field(utf8.encode('$period'));
  field(utf8.encode('$epoch'));
  return out.toBytes();
}
