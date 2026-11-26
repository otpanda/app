#!/usr/bin/env bash
# UNRUN until a CI emulator executes it. Needs: EXPECT_API, adb with one booted emulator, ANDROID_HOME (build-tools with d8), KOTLIN_LIB, ANDROID_JAR.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-offline-totp-runtime-out}; mkdir -p "$out"
d8=$(ls -d "$ANDROID_HOME"/build-tools/*/d8 | sort -V | tail -1)
work=$(mktemp -d)
java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect \
  -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar:$ANDROID_JAR" -d "$work/classes" \
  "$root/TotpCalculator.kt" "$root/SeedCustody.kt" "$root/AndroidSeedVault.kt" "$root/NoBackupSeedRecordStore.kt" "$root/runtime/RuntimeFixture.kt"
python3 - "$work/classes" "$work/classes.jar" <<'PYZIP'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w') as archive:
    for path in root.rglob('*.class'):
        archive.write(path, path.relative_to(root))
PYZIP
"$d8" --lib "$ANDROID_JAR" --output "$work/fx.zip" "$work/classes.jar" "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar"
adb push "$work/fx.zip" /data/local/tmp/otpanda-fx.zip >/dev/null
adb shell rm -rf /data/local/tmp/otpanda-fixture; adb shell mkdir -p /data/local/tmp/otpanda-fixture
# Pass/fail comes ONLY from verify-log.py (non-empty log, one END marker per phase, minimum oks, result markers, expected API, no crash markers).
# adb exit codes are ignored on purpose: old images return 0 on crashes. A shell-uid, SELinux or d8 failure surfaces as a verifier failure
# and is a HARNESS problem, not evidence about custody; read fixture.log before blaming the source.
: "${EXPECT_API:?Set EXPECT_API to the emulator API level}"
actual=$(adb shell getprop ro.build.version.sdk | tr -d '\r\n')
[ "$actual" = "$EXPECT_API" ] || { echo "HARNESS FAIL: emulator API $actual != expected $EXPECT_API" >&2; exit 3; }
: > "$out/fixture.log"
for phase in env secure-default seam-provision seam-restart seam-loss seam-orphan size cleanup; do
  echo "== phase $phase" >> "$out/fixture.log"
  adb shell "CLASSPATH=/data/local/tmp/otpanda-fx.zip app_process /system/bin org.otpanda.totp.RuntimeFixtureKt $phase" 2>&1 | tr -d '\r' >> "$out/fixture.log" || true
done
adb logcat -d -b crash 2>&1 | tr -d '\r' > "$out/logcat-crash.txt" || true
adb shell rm -rf /data/local/tmp/otpanda-fixture /data/local/tmp/otpanda-fx.zip || true
cat "$out/fixture.log"
python3 "$root/runtime/verify-log.py" "$out/fixture.log" "$EXPECT_API"
