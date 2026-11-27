# Wrapping-key emulator fixture (debug only, synthetic)

Runs the REAL `androidWrappingKeyCore` (real AndroidKeyStore, real noBackupFilesDir, real directory fsync) inside a separate debug APK
(`org.otpanda.wrappingkey.fixture`). It never touches production aliases or namespaces (`fx-*` only), is never part of the app, and is unrelated to
`tool/offline-totp/runtime`. Nothing here is registered or wired into production.

## Invocation (CI emulator, API 34)
    EXPECT_API=34 ANDROID_HOME=$ANDROID_HOME KOTLIN_LIB=<kotlin-2.0.20 lib dir incl. kotlin-stdlib-2.0.20.jar> ANDROID_JAR=<android-35/android.jar> \
      bash tool/android-wrapping-key/runtime/run-fixture.sh wrapping-key-runtime-out
Pass means `VERIFY PASS` from `verify-log.py` (exit 0). `wrapping-key-runtime.workflow.yml` is a manual-dispatch workflow (copy into .github/workflows).
Self-test of the verifier: `python3 tool/android-wrapping-key/runtime/verify_log_test.py`.

## Phases (each a fresh instrumentation process)
env, create (61-byte blob in noBackup, alias present), reopen (new process reads the same key; duplicate create returns it, blob unchanged), duplicate,
alias-lost (blob present, alias deleted: read and create -> MISSING_ALIAS, blob preserved, no alias regenerated), alias-lost-restart (same after restart; explicit purge),
corrupt (flipped tag, truncated, directory-in-place-of-blob -> CORRUPT, nothing repaired or deleted), orphan (alias without blob = absent; create reuses it),
threads (6 threads, separate core instances: one creator, one key), race-procs (3 separate OS processes created at a shared instant: one creator, one key),
crash-start (a service process blocks after the temp file fsync, before the rename, then is SIGKILLed), crash-recover (read is absent, create succeeds, stale temp swept), delete, cleanup.

## Not covered (an emulator cannot show these)
Locked device / pre-first-unlock (the fixture only asserts the user is unlocked; LOCKED mapping stays JVM-fake tested), uninstall and backup/restore behavior,
hardware or StrongBox backing (a software Keystore is accepted), real KeyPermanentlyInvalidated. `alias-lost` deletes the alias through KeyStore.deleteEntry, which models
"alias gone" but not every platform-side invalidation. The error-class mapping in WrappingKeyAndroid.kt is still a best reading until this runs.
Not yet run anywhere: build tools (aapt2, d8, zipalign, apksigner) were not available where this was authored; the Kotlin sources compile against android-35.jar.
