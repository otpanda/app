# Native recovery validation gates

Inactive source only. Run these against a stable package/signing identity before any enrollment-enabled release. Never use production accounts for destructive device-policy tests.

## Policy and signing
- API30 and current Android, separate biometric-capable and credential-only devices.
- KeyInfo must show authentication required, per-use and permitted strong-biometric/device-credential types. Record provider behavior without treating it as remote attestation.
- Direct signature without OS verification must fail. OS fingerprint/face must be strong, weak biometric must not authorize the operation.
- PIN/password/pattern fallback signs the same challenge. Cancel/error returns exactly one failure and permits a later attempt.
- Returned CryptoObject Signature identity must satisfy strict equality on each tested device, no blind relaxation if provider differs.
- Lock removal/forced reset, biometric enrollment and credential changes have documented recoverable or failed-closed behavior. Never silently regenerate an alias during recovery.

## Lifecycle and races
- Cancel before prompt, during prompt, just after success, simultaneous cancel/success.
- Activity pause due to credential screen must not prematurely cancel. Stop/destroy in credential UI, home/background, multiwindow, rotation and process death need explicit observed outcomes.
- No late signature reaches a disposed callback. Sensitive byte buffers zero on discarded results. No stuck pending flag or listener leak after missing/delayed OS callback.
- Two wrapper instances cannot replace a key or launch concurrent prompts. Cross-process host unsupported.

## Metadata and safety
- Kill before/after key generation, before server enrollment, after server commit but before confirmation, before/after atomic metadata commit.
- Same-key retry reconciles only under fresh enrollment authority and proof of possession. Revoked key cannot reenroll or undo revocation.
- Confirmed metadata with missing/mismatched key denies before key creation/network enrollment. Show use-another-sign-in-method guidance, no replacement/reset promise.
- Missing/corrupt/unreadable/oversized metadata remains distinct. Check backup/cloud/device-to-device transfer cannot turn a nonportable record into an apparently usable key.
- No recovery enrollment occurs in fictional preview, unstable package or debug identity.

## Protocol and effects
- Shared fixed public vector passes Kotlin and server. Client wall clock behind/ahead, prompt crossing expiry, stale generation and revoked credentials/key deny correctly at server.
- Informed account identity must be shown using verified display data. Prompt purpose alone is not multi-account confirmation.
- Server fixes the enrollment/recovery effect and action digest, then final effect transaction checks current key/generation/revocation and single use. No arbitrary caller recovery digest can acquire broad effects.
- Lost-key replacement and credential removal/reset are separate explicitly authorized designs, absent from current primitive.

No claim is cleared by checking this document. Attach device versions, exact test builds, observations and pass/fail evidence to an actual validation record.
- Revoked server key with intact alias/record: opaque denial must show safe use-another-sign-in-method guidance, never a retry loop or automatic key deletion/reenrollment.
