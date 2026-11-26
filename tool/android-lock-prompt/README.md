# Lock-prompt runtime qualification (debug only, synthetic)

Question: does the real Credential Manager prompt, shown from an Activity that behaves like the composed MainActivity (`onStop` -> `LocalLockRecoveryHost.reset()`), stop its own host Activity, and so self-cancel the attempt? Unproven until the emulator run.

Run (booted API 34 emulator, repo root after tool/bootstrap.sh): `tool/android-lock-prompt-qualification.sh OUT`
Env: EXPECT_API (34), DEVICE, PKG (app.otpanda), APK (skip build), REQUIRE_NO_SELF_STOP=1 (fail if mimic_idle sees a stop with no user action).
CI wiring (primary): emulator job like native-lifecycle-qualification.yml (API 34 google_apis x86_64), steps: tool/bootstrap.sh, `python3 tool/android-lock-prompt/check.py`, `python3 tool/android-lock-prompt/selftest.py`, the runner, upload OUT (always).

Scenarios (adb drives the user actions and writes `ev=mark` lines into the same logcat stream):
- observe_idle / observe_home: mimic=0, the fixture never resets. Shows what the OS does to the Activity with the prompt up (idle, then HOME, return).
- mimic_idle: mimic=1, no user action. Any `onStop` here before a mark is a PROMPT-CAUSED self-stop.
- mimic_back / mimic_home: user action marks BACK or HOME. An `onStop` after the HOME mark is a user-caused stop.
Verifier reports per scenario: prompt_ui (focus window not the app), self_stop_before_any_user_action, user_stop_after_mark, outcome, exception class, event sequence. It fails closed if an event is missing, no prompt UI/screenshot, outcome delivered twice, wrong API, or a crash. By default a self-stop is reported, not failed.
Limits: emulator only. With no credential provider the prompt may not appear; that is reported as inconclusive (fail), never a pass. Fake begin transport only; no finish; no real key, token or account. The fixture's Passkeys copy is guarded to use the same call as the host (check.py).

Review hardening (N4 review):
- A prompt only counts when the idle focus window is a credential provider (com.android.credentialmanager, or gms with a credential/identity/fido/passkey activity). App, keyguard, launcher, SystemUI and ANR dialogs do not count.
- Any prompt_error/prompt_result/outcome before the idle check fails the run. All 5 scenarios wait 10 s and capture focus plus a screenshot before any user action.
- Asserted outcomes: mimic_idle stays pending; mimic_back USER_CANCELLED once; mimic_home ABORTED once after the HOME mark; observe_idle USER_CANCELLED once after BACK. A HOME scenario without its HOME mark fails.
- CI must set REQUIRE_NO_SELF_STOP=1. Locally it is a reported fact.
- SCOPE: the allowCredentials id is synthetic, so the provider shows at most a no-passkey/error sheet. This is NOT evidence about a real credential selection or the biometric step. A virtual credential seed was not added (no authenticator we can seed without real key material or provider-specific tooling), so a pass is scoped to that sheet.
- SCOPE: a plain Activity hosts the prompt. The real MainActivity/FlutterActivity host is NOT covered: Dart does not start an attempt yet and the engine needs the full app, which is not bounded here. A pass is NOT activation proof.
