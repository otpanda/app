# Lock-prompt runtime qualification (debug only, synthetic) - UNRUN until an API 34 emulator executes it

Question: with the repo's real MainActivity lifecycle hooks and the real LocalLockRecoveryHost, does the real Credential Manager selector stay up, cancel, abort on HOME, and finish an unlock or a disable? Does the prompt itself stop the host Activity (prompt-caused self-stop)?

What runs (all debug source set, installed by install-fixture.py, never in main/release):
- `LockPromptHostActivity` EXTENDS the real `MainActivity` (real engine, AppLockHost, onStop/onDestroy resets, cleanUpFlutterEngine dispose). After the real configureFlutterEngine it re-registers the REAL `LocalLockRecoveryHost` (idempotent) with a FAKE `LockApi` on an in-process loopback messenger and drives the real channel handler `app.otpanda/lock-recovery` (start, consumeUnlock). Real Passkeys (Credential Manager), real Effects (flag file + AppLockHost), real Env. Seeded synthetic state: a fake device id and the real flag file path.
- `SyntheticProviderService` + `SyntheticAssertionActivity`: a debug credential provider that offers one entry and returns a WebAuthn-shaped assertion signed by a throwaway in-memory key per call. No biometric step.
- `FakeLockApi`: begin/finish with the real wire shapes LocalLockRecovery validates; finish checks intent, lockGeneration, token and the challenge round trip. No signature verification.
- `lock_fixture_main.dart`: build target (`-t`) that runs no app Dart, so no Dart app-lock UI competes with the prompt.
Source edits outside tool/android-lock-prompt (required, tiny): `LocalLockRecoveryHost.register(activity, messenger, api: LockApi = HttpsLockApi())` (default parameter, nothing else) and `MainActivity` becomes `open class` (primary-owned file, one word). The production call site stays the two-argument default.

Run (booted API 34 emulator, repo root after tool/bootstrap.sh): `tool/android-lock-prompt-qualification.sh OUT`
Env: EXPECT_API (34), DEVICE, PKG, APK (skip the build), RELEASE_APK (negative check on a release artifact), REQUIRE_NO_SELF_STOP=1 (CI must set it).
CI wiring (primary): emulator job like native-lifecycle-qualification.yml (API 34 google_apis x86_64): tool/bootstrap.sh; `python3 tool/android-lock-prompt/check.py`; `python3 tool/android-lock-prompt/selftest.py`; the runner; upload OUT with `if: always()`. Separately run `python3 tool/android-lock-prompt/check-release-artifact.py <release apk>` on a release build (kept out of the runner so release repair stays separate).

Enablement (see ENABLEMENT.md): the runner appends the synthetic provider component to `settings secure credential_service`, reads it back, and fails the harness if it is missing. A framework rejection ("does not have the required capabilities") or no provider_begin_get call is a HARNESS failure, never a pass.

Scenarios (adb drives user actions, written into the same log as marks):
- unlock_idle: prompt up 12 s, nothing pressed. Pending outcome expected. Any onStop before a mark is a PROMPT-CAUSED self-stop (fact; fails only with REQUIRE_NO_SELF_STOP=1).
- unlock_back: BACK -> USER_CANCELLED once. unlock_home: HOME -> onStop after the mark, ABORTED once.
- unlock_select: tap the synthetic entry (uiautomator) -> provider selected, fake finish ok with matching challenge, UNLOCK_GRANTED once, consumeUnlock true then false.
- disable_select: the same with the disable intent -> DISABLED once, flag file gone.
Every scenario first requires: the credential selector window focused (credentialmanager, or gms credential activity; keyguard/ANR/launcher/app do not count), the synthetic entry visible in the uiautomator dump (an error or other-provider sheet does not count), a screenshot, provider_begin_get, and no outcome before the idle check.

Scope of a pass: real MainActivity hooks + real host + real Credential Manager with THIS fixture provider on the emulator image. NOT Google Password Manager, Samsung, biometrics, server signature verification or hardware. Locally verified: compile of the whole set against real androidx.credentials 1.3.0, the Flutter embedding jar and android.jar 35; verifier/tap/release-check self-tests; source guard. Not verified: any device behavior, the Gradle build, the settings write, the selector tap path.
