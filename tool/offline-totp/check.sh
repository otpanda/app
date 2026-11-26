#!/usr/bin/env bash
set -euo pipefail
: "${KOTLIN_LIB:?Set KOTLIN_LIB to Kotlin2.0.20 compiler jars}"
root=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
compile(){ java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar${1:+:$1}" -d "$2" "${@:3}"; }
compile '' "$out/classes" "$root/TotpCalculator.kt" "$root/TotpCalculatorTest.kt"
java -cp "$out/classes:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.totp.TotpCalculatorTestKt
# Local seed custody logic against an in-memory SOFTWARE fake vault (not Keystore evidence).
compile '' "$out/custody" "$root/TotpCalculator.kt" "$root/SeedCustody.kt" "$root/SeedCustodyTest.kt"
java -cp "$out/custody:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.totp.SeedCustodyTestKt
bash "$root/release-guard.sh" "$root/../.."
# Guard self-test: a production file using the seam must make the guard fail.
tmp=$(mktemp -d); mkdir -p "$tmp/tool/offline-totp" "$tmp/lib"
cp "$root/SeedCustody.kt" "$tmp/tool/offline-totp/"; echo 'val x = LocalSeedCustody(v, s, allowSoftwareKeysForTests = true)' > "$tmp/lib/Wiring.kt"
if bash "$root/release-guard.sh" "$tmp" >/dev/null 2>&1; then echo 'FAIL guard self-test did not trip' >&2; exit 1; fi
rm -rf "$tmp/lib"; mkdir "$tmp/lib"
echo 'val x = LocalSeedCustody(v, s, true)' > "$tmp/lib/Wiring.kt"
if bash "$root/release-guard.sh" "$tmp" >/dev/null 2>&1; then echo 'FAIL positional-constructor self-test did not trip' >&2; exit 1; fi
rm -rf "$tmp"; echo 'PASS release guard self-test trips on named and positional production use'
python3 "$root/runtime/verify-log-test.py"

# Android adapters compile against the platform jar when one is provided; compiling is not device behavior.
if [ -n "${ANDROID_JAR:-}" ]; then
  compile "$ANDROID_JAR" "$out/android" "$root/TotpCalculator.kt" "$root/SeedCustody.kt" "$root/AndroidSeedVault.kt" "$root/NoBackupSeedRecordStore.kt"
  printf '%s\n' 'PASS inactive Android seed vault and record store compile; Keystore, hardware level, uninstall and backup behavior remain unverified'
  compile "$ANDROID_JAR" "$out/fixture" "$root/TotpCalculator.kt" "$root/SeedCustody.kt" "$root/AndroidSeedVault.kt" "$root/NoBackupSeedRecordStore.kt" "$root/runtime/RuntimeFixture.kt"
  printf '%s\n' 'PASS emulator fixture source compiles (UNRUN: executes only in the manual emulator workflow)'
  # Also compile against API 30 (minimum supported) when provided, to catch newer-API use such as readNBytes (API 33) or KeyInfo.securityLevel (API 31).
  if [ -n "${ANDROID_JAR_API30:-}" ]; then
    compile "$ANDROID_JAR_API30" "$out/android30" "$root/TotpCalculator.kt" "$root/SeedCustody.kt" "$root/AndroidSeedVault.kt" "$root/NoBackupSeedRecordStore.kt"
    printf '%s\n' 'PASS adapters compile against API 30 android.jar (compile-time API surface only, not runtime on API 30-32 devices)'
  fi
fi
