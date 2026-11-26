# Native-owned local-lock recovery finish (proposal, inactive)

Source: `LocalLockRecovery.kt` (logic, JVM), `HttpsLockApi.kt` (transport), `LocalLockRecoveryTest.kt`, and the Android glue `tool/android-native/main/LocalLockRecoveryHost.kt`.
Server contract read from otpanda-api `src/local-lock-recovery-http.js` (begin and finish, bearer device session, no Origin, exact intents `local-unlock-once` and `local-lock-disable`).

## What native owns
- The `lockGeneration` (32 random bytes, base64url, one per attempt), both HTTPS calls (fixed origin, two paths, POST, no redirects, no cookies, no Origin, 24 KB caps, system TLS trust), the begin validation (same rules as Dart `passkeyRequestJson`), the passkey prompt with a retained `CancellationSignal`, and the finish response validation.
- The local effect. `local-lock-disable`: native deletes the lock flag and clears FLAG_SECURE only after a 200 whose body has exactly `intent, lockGeneration, deviceId, generation`, with intent and lockGeneration equal to this attempt, `deviceId` equal to the native-stored device id (read again at the effect) and `generation` a safe non-negative integer. `local-unlock-once`: native records a one-use 15 s grant that Dart reads once with `consumeUnlock`. Neither can be granted by any Dart call.
- Cancellation. `reset()` bumps the generation, cancels the prompt, ends the attempt with ABORTED, and drops every late begin, assertion or finish result. One attempt at a time (BUSY otherwise). A device-id change or a lock that is no longer enabled is re-checked before the prompt, before finish and at the effect.

## Dart wiring the primary needs (not in this patch; lock sources are not in origin/main)
1. New channel `app.otpanda/lock-recovery`: `start{intent: 'local-unlock-once'|'local-lock-disable', bearer}` returns the outcome name once; `cancel`; `consumeUnlock` returns bool.
2. Replace `NativeLocalLockRecovery.verify` plus `disableAfterPasskey`. Delete `disableAfterPasskey` and `PasskeyDisablePlatform` from `AppLockHost` and `native_app_lock.dart`. `LocalLockController.recover(disable)` becomes: take `await session.accessToken()`, call `start`, then switch on the outcome:
   - DISABLED: `enabled = false`, unlock (same foreground or resume handling as today), rotate.
   - UNLOCK_GRANTED: call `consumeUnlock`. Only when it returns true, unlock as today.
   - USER_CANCELLED and ABORTED: no message (nothing changed).
   - NETWORK_UNAVAILABLE: "No connection. App lock remains on." OUTCOME_UNKNOWN: "Could not confirm. App lock remains on. Try again."
   - UNAUTHORIZED: `forceRenew` and retry once. RESTART: start again. Everything else: generic failure, lock stays on.
   Dart `lockGeneration` stops being the server binding. It can stay as a UI rotate counter.
3. Call `cancel` on sign-out, session change or device change, and on dispose.
4. MainActivity: register the host after `AppLockHost.register(...)` with `LocalLockRecoveryHost.register(this, messenger)`. Call `LocalLockRecoveryHost.reset()` in `onStop` and `onDestroy`. Do not cancel on pause alone.

## Evidence and limits
- RUN: `check.sh` runs the JVM tests (success paths, 12 response-mismatch cases, begin schema bounds, honest-failure mapping, passkey outcomes, reset at every stage, device and lock changes, strict JSON, transport with a fake connection). Mutation checks: removing the lockGeneration check, the device re-check, or the 5xx mapping each made a test fail. The glue compiles against API 35 `android.jar`, the Flutter embedding jar and minimal stubs of the androidx.credentials classes that `PasskeyHost` already uses. It was not compiled against the real library.
- NOT RUN: OS credential UI, real network, TLS, process death, multi-window, Credential Manager cancellation behavior, a real server round trip.
- Known gaps: the server does not echo the owner, so the owner is bound only through the bearer. Begin expiry uses the device clock, as in Dart, so a clock far ahead fails closed (MISMATCH). A bearer with 60 s left can expire during a 120 s ceremony (finish 401, retry). A finish 5xx or an unreadable answer is OUTCOME_UNKNOWN: the one-use ceremony may be consumed, no local effect is made, start over. `reset()` must run on the main thread; the logic relies on that, not on locks.
- Device checklist additions (manual): cancel the prompt, background the app mid-prompt, sign out mid-prompt, airplane mode at begin and at finish, rotate the screen, kill the process mid-prompt, confirm the flag survives every failure and goes only on a real finish.
