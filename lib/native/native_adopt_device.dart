import 'dart:typed_data';

import 'native_action_proof.dart';
import 'native_device_proof.dart';
import 'native_device_routes.dart';

enum AdoptOutcome {
  /// Typed 200 {status:'enrolled', keyId} matching the challenge, native
  /// confirmation saved, and only then the pending anchor cleared.
  adopted,

  /// Nothing confirmed. Anchor and key kept; a fresh begin may be tried.
  notConfirmed,

  /// A check failed before any prompt. Nothing signed.
  refused,
  cancelled,
  notStarted,
}

/// Adopts a key the server already holds for this phone (needsAdopt). Needs a
/// step-up signature, which the host refuses while STEP_UP_ENABLED is false.
/// Never deletes a key. The ADD record or recovery anchor is cleared ONLY
/// after a typed confirm and a saved native confirmation.
class AdoptDriver {
  AdoptDriver({
    required this.source,
    required this.routes,
    required this.ownerId,
    required this.accountEmail,
    required this.onAdopted,
    required this.clearAnchor,
    required this.expectedKeyId,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final DeviceProofSource source;
  final DeviceStatusRoutes routes;
  final String ownerId, accountEmail;

  /// The keyId the server reported for this phone's digest: mandatory.
  final String expectedKeyId;
  final Future<void> Function(String keyId) onAdopted;
  final Future<void> Function() clearAnchor;
  final int Function() _now;
  final _signed = <String>{};

  Future<AdoptOutcome> adopt() async {
    final text = adoptPrompt(accountEmail);
    if (text == null) return AdoptOutcome.refused;
    if (await source.availability() != DeviceProofAvailability.available) {
      return AdoptOutcome.notStarted;
    }
    final Uint8List? spki;
    try {
      spki = await source.publicKeyOrNull();
    } catch (_) {
      return AdoptOutcome.notStarted;
    }
    if (spki == null) return AdoptOutcome.notStarted;
    final String digest;
    try {
      digest = publicKeyDigest(spkiToJwk(spki));
    } on FormatException {
      return AdoptOutcome.notStarted;
    }
    EnrollChallenge? c;
    try {
      c = await routes.adoptBegin(digest);
    } catch (_) {
      return AdoptOutcome.notConfirmed;
    }
    if (c == null) return AdoptOutcome.refused;
    final now = _now();
    if (c.purpose != 'step-up' ||
        c.ownerId != ownerId ||
        c.keyId != expectedKeyId ||
        c.actionDigest != adoptActionDigest(digest) ||
        c.expiresAt <= now ||
        c.expiresAt > now + maxProofLifetimeMs) {
      return AdoptOutcome.refused;
    }
    // A challenge is signed at most once; a lost finish needs a fresh begin.
    if (!_signed.add(c.token)) return AdoptOutcome.notConfirmed;
    final DeviceProofFields fields;
    try {
      fields = DeviceProofFields(
        purpose: 'step-up',
        ownerId: c.ownerId,
        keyId: c.keyId,
        generation: c.generation,
        challenge: c.challenge,
        actionDigest: c.actionDigest,
        expiresAt: c.expiresAt,
      );
      fields.message;
    } on FormatException {
      return AdoptOutcome.refused;
    }
    final Uint8List sig;
    try {
      sig = await source.sign(fields, displayText: text);
    } on DeviceProofFailure catch (e) {
      return e.kind == DeviceProofFailureKind.cancelled
          ? AdoptOutcome.cancelled
          : AdoptOutcome.refused;
    }
    if (sig.length != 64) return AdoptOutcome.refused;
    String? id;
    try {
      id = await routes.adoptFinish(digest, c.token, sig);
    } catch (_) {
      return AdoptOutcome.notConfirmed;
    }
    if (id == null || id != c.keyId) return AdoptOutcome.notConfirmed;
    try {
      await onAdopted(id);
    } catch (_) {
      return AdoptOutcome.notConfirmed; // anchor kept
    }
    try {
      await clearAnchor();
    } catch (_) {
      // Confirmed and saved; a leftover anchor only re-reconciles.
    }
    return AdoptOutcome.adopted;
  }
}
