# Inactive offline TOTP calculator

A pure Kotlin/JCA calculator accepts a `SecretKey` handle, explicit Unix seconds and algorithm/digits/period metadata. It calls `Mac.init(key)` and never calls `key.encoded`, imports, exports, persists or syncs a seed. It has no app-host wiring, Flutter channel, network path or cloud endpoint. It does not claim secure local storage is implemented.

Run with the same Kotlin2.0.20 compiler-library directory containing the versioned stdlib jar and compiler jars, as used by `tool/android-recovery/check.sh`:

```sh
KOTLIN_LIB=/path/to/kotlin-compiler-library-directory bash tool/offline-totp/check.sh
```

The standalone JVM test exercises all18 RFC6238 vectors, leading zeros,6/7/8digits, period boundaries, a nondefault period, timestamps beyond2038, invalid metadata/overflow and provider/key rejection. A synthetic JCA Provider accepts a handle with throwing/counted getEncoded and returns the RFC SHA1 code with zero encoding reads. This tests calculator behavior, not a real secure provider. Only published synthetic seeds are used. Successful JVM execution is not Android Keystore, hardware, offline lifecycle or key invalidation evidence. Provider errors propagate. There is no software/raw-key fallback when a key handle is rejected.

JCA's provider may need raw bytes for software keys; this calculator does not make a software `SecretKeySpec` nonextractable. Real Android integration must provision a separate local key from the authorized cloud seed, verify the actual imported key's available algorithm and runtime protection on the intended device, and handle deletion/invalidation. This calculator does not set an unlock policy or choose plaintext/software fallback. The cloud remains intentionally server-readable for authorized generation/automation.

A retained offline seed can continue generating after cloud device revocation until the service rotates that seed or the device reconnects and cooperates. Do not promise immediate offline revocation. Clock validity, sync/version conflicts, tombstones, user-visible state and strong export action binding are separate unfinished integration work.

Sources:
- RFC6238 primary/reference implementation and AppendixB: https://www.rfc-editor.org/info/rfc6238/
- Android Mac API, `init(Key)` and HMAC algorithm surface: https://developer.android.com/reference/javax/crypto/Mac?authuser=31
- Android Keystore restrictions/security model: https://developer.android.com/privacy-and-security/keystore

No promise is made that a particular imported SHA1/256/512 key is supported in a particular device's secure hardware. This source does not attest a symmetric key, claim browser storage equivalence or select a migration format.

Algorithm is mandatory, with no SHA1 default. The integration must obtain digest/digits/period from the same authenticated versioned seed record used at import, persist that metadata atomically with its key alias and refuse mismatch/missing metadata. Do not infer allowed digest from software key.algorithm or treat successful software HMAC as device digest-binding proof. This metadata/storage integration is not implemented here.

## Local seed custody (inactive, not wired)

- `SeedCustody.kt`: pure logic (strict v1 record codec, `LocalSeedCustody`: provision, generate, delete, accounts, reconcile). `AndroidSeedVault.kt`: Keystore HMAC import (SDK 30+, no user-auth requirement so codes work on a locked device). `NoBackupSeedRecordStore.kt`: one atomic file per account in noBackupFilesDir so records are not restored without keys.
- Provision is create-only; rotation is explicit delete then provision. Seeds must be 10..128 bytes and are zeroed on every path. Secure hardware is required by default and a weaker key is rolled back. The record is written only after the key is verified; delete removes the record first, then the key. Reconcile only removes orphan keys, never recreates anything.
- Tests: `check.sh` runs JVM tests against an in-memory SOFTWARE fake vault, and compiles the Android adapters when `ANDROID_JAR` is set. These are not evidence of real Keystore import, hardware level, lock behavior, invalidation, uninstall or backup behavior. Those need device qualification before any real seed is enrolled.
- No sync, no real seed, no enrollment, no wiring into the app host.

Fixes after review (v2): no API 33 calls (bounded read loop; adapters also compile against the API 30 jar when `ANDROID_JAR_API30` is set, URL platform-30_r03.zip, sha256 f3f5b757...d84e, entry android-11/android.jar; unpinned in ci.sh). An unlistable existing record directory is an error, never an empty set (reconcile would wipe keys). Provision removes a record-less orphan key then proceeds; a real record is never replaced. Seeds above 64 bytes that fail import report `vault_unsupported_seed` (best effort; the real Keystore limit is unproven). The software-key bypass is a test seam named `allowSoftwareKeysForTests`; app code must never set it. Zeroing covers only the caller's array; SecretKeySpec, provider and JNI copies are not guaranteed wiped. The hardware requirement is a candidate policy, not a recorded user preference, and locked-device use versus an app lock is unresolved until wiring. The security level is recorded as `secure_hardware` or `software` (no StrongBox distinction).

## Emulator runtime fixture (API34 synthetic runtime verified)

`runtime/RuntimeFixture.kt` (phases), `runtime/FixtureRunner.kt` (instrumentation), `runtime/AndroidManifest.xml`, `runtime/run-fixture.sh` and `.github/workflows/offline-totp-runtime.yml` (manual dispatch, API 34 and 30 emulators). A tiny debug-only APK (package org.otpanda.totp.fixture, never in the app) is built with kotlinc, d8, aapt2 and apksigner, installed, and run with one `am instrument` process per phase, so it has a real app UID, application context and noBackupFilesDir. A first attempt through shell-uid `app_process` failed on provider availability (harness, not custody). Phases use the RFC test seeds only: secure-default (observed: accepted as secure_hardware, or refused and rolled back), seam import and RFC codes for SHA1/256/512, create-only, restart persistence, key loss giving KeyMissing without recreation, orphan cleanup, and a 65-byte seed observation. `verify-log.py` is the only pass/fail source; `extract-instrument.py` converts `am instrument` output and fails on a missing or non -1 INSTRUMENTATION_CODE. Results on an emulator image prove nothing about physical hardware, StrongBox, lock behavior, uninstall/reinstall or backup.


API34 isolated instrumentation run on26November2026 passed: https://github.com/otpanda/app/actions/runs/45813877902 . Artifact: https://github.com/otpanda/app/actions/runs/45813877902/artifacts/15114675750 . Default refused software keys and rolled back; explicit test seam generated SHA1/256/512 RFC codes with reported software keys; separate processes retained records/codes; simulated key loss and orphan reconciliation passed;65byte key was accepted. Raw perphase instrumentation output and empty crash log inspected. This does not establish API30 runtime, physical hardware, lock/unlock behavior, actual uninstall/reinstall or backup/restore. Final fixture record cleanup passed; the teardown uninstall command did not preserve independent absence proof. No real seed, host wiring or production policy selection.

## Native custody v2 (owner/version/epoch contract), UNWIRED

`NativeCustody.kt` (`NativeSeedCustodyCore`, pure JVM), `OwnerStateFileStore.kt` (atomic per-owner state in noBackupFilesDir) and `AndroidSeedVault.probe()`
implement the Kotlin side of the Dart `NativeSeedCustody` contract. The v1 `LocalSeedCustody` above is superseded but kept until v2 is reviewed; retire it then.
Key alias = SHA-256 of the same length-prefixed AAD as Dart `custodyAad` (pinned by a cross-language test vector), so a record cannot move to another
owner, entry, version, epoch or parameter set. Software-backed Keystore keys are accepted (OS-encrypted); capability() reports hardware vs OS-encrypted by probe.
Tests: `NativeCustodyTest.kt` (JVM fakes only). Not proven: real Keystore, hardware level, lock, uninstall/backup behavior, 64+ byte seeds, rollback or replacement of
the state file by code running as the app UID (not prevented). `NativeCustodyChannel.kt` is a Flutter-free MethodChannel handler proposal (JVM-tested); MainActivity wiring is not done. Emulator fixture phases v2-* exist (runtime/RuntimeFixtureV2.kt) and are UNRUN until the manual workflow executes them.
