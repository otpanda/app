# Android wrapping-key adapter (offline cache key)

Status: source and JVM-fake tests only. Not registered in the app unless the overlay is run with `--register`. Nothing here ran on a device or against the real Keystore.

## What it stores

A random 32-byte key for the encrypted offline database, per install namespace, behind the same SecretStore boundary as the Windows and macOS adapters (read, create-if-absent, explicit delete). It is separate from seed custody and signing keys (own channel `app.otpanda/wrapping-key`, own alias prefix `otpanda.wrapkey.v1.<ns>`, own directory).

The key is exportable (the database needs the raw bytes) but is only stored wrapped: AES-256-GCM under a non-exportable AndroidKeyStore key, no user-authentication requirement, no StrongBox or hardware claim. The blob is exactly 61 bytes (version 1, 12-byte IV, 32-byte ciphertext, 16-byte tag), authenticated with the namespace as AAD, in `noBackupFilesDir/otpanda-wrapping-key-v1/<ns>.key`. `<ns>.lock` is a persistent lock file.

## Create-only and locking

Follows `InstallIdFile` (no hard links; the platform refused them for app data): a JVM monitor plus an OS `FileLock` on `<ns>.lock`, a temp file with fsync, an absence re-check under the locks, an atomic same-directory rename, directory confirmation, then a read-back and unwrap. Readers do not lock. A published blob is never deleted or overwritten by create or read. Stale `<ns>.tmp-*.part` files are swept only by a create or delete that holds the locks, not at app start.

## Outcomes (wire codes; details always `{outcomeUnknown: bool}`)

| Situation | Result |
| --- | --- |
| No blob, definite NoSuchFile | read returns null |
| Blob present, key unwraps | the key; create returns the winner with created=false |
| Alias exists, no blob (crashed create) | absence; create reuses the alias |
| Blob present, Keystore alias gone or permanently invalid | `missingAlias`. Never recreated, replaced or purged. Read and create fail the same way |
| Blob wrong size or version, not a regular file, symlink, or GCM tag mismatch | `corrupt`. Never repaired, replaced or deleted by read or create |
| User storage not unlocked (UserManager.isUserUnlocked false), or storage locks mid-call | `locked`, known not applied before publish |
| Any other IO, lock-timeout or Keystore failure | `unavailable`; outcomeUnknown only if the failure came at or after the rename (create) or after delete started |
| Bad arguments | `unavailable`, known not applied |

The Dart adapter maps `missingAlias` to `SecretStoreError.corrupt` because secret_store.dart has no dedicated value. Same caller rule either way. A `keyMissing` enum value would let the UI say which; that file is primary-owned.

Explicit delete removes the blob (even a corrupt one) and then the Keystore key. A crash between the two leaves an orphan alias, which is reused. No code path deletes a key or blob because of an error, and nothing generates data or keys without the caller asking.

## Unverified until installed qualification

Real Keystore generation and decryption, error classes on real devices (the mapping of AEADBadTagException, KeyPermanentlyInvalidatedException, UnrecoverableKeyException is a best reading), behavior before first unlock and during Direct Boot, rename, fsync and FileLock on app data, backup and device-transfer exclusion (the existing overlay already sets the extraction rules), uninstall and reinstall (blob and alias both go, so a reinstall looks absent), factory reset, and whether Keystore aliases survive an app data clear (the blob does not, the alias may; an orphan alias is reused). The host file `host/WrappingKeyHost.kt` needs the Flutter embedding and was not compiled here.

Run: `KOTLIN_LIB=... ANDROID_JAR=... bash tool/android-wrapping-key/check.sh`.
