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
