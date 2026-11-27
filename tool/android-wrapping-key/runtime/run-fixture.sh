#!/usr/bin/env bash
# UNRUN until a CI emulator executes it. Builds a debug-only fixture APK (package org.otpanda.wrappingkey.fixture, separate from the offline-totp fixture) around the REAL
# wrapping-key sources and runs one instrumentation process per phase. Needs: adb with one booted emulator, EXPECT_API, ANDROID_HOME (build-tools: aapt2, d8, zipalign,
# apksigner), keytool, python3, KOTLIN_LIB, ANDROID_JAR. Pass/fail comes ONLY from verify-log.py. A build/install/instrumentation failure shows up as a verifier
# failure and is a HARNESS problem, not custody evidence. Never ships in the app. Usage: run-fixture.sh [OUT_DIR]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
out=${1:-wrapping-key-runtime-out}; mkdir -p "$out"
: "${EXPECT_API:?Set EXPECT_API to the emulator API level}"
pkg=org.otpanda.wrappingkey.fixture
bt=$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)
work=$(mktemp -d)
java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect \
  -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar:$ANDROID_JAR" -d "$work/classes.jar" \
  "$root/WrappingKey.kt" "$root/WrappingKeyAndroid.kt" "$here/WrappingKeyFixture.kt" "$here/RaceServices.kt" "$here/FixtureRunner.kt"
mkdir "$work/dex"; "${bt}d8" --lib "$ANDROID_JAR" --min-api 30 --output "$work/dex" "$work/classes.jar" "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar"
"${bt}aapt2" link -o "$work/base.apk" -I "$ANDROID_JAR" --manifest "$here/AndroidManifest.xml" --min-sdk-version 30 --target-sdk-version 34
(cd "$work/dex" && zip -q -j "$work/base.apk" classes*.dex)
"${bt}zipalign" -f 4 "$work/base.apk" "$work/aligned.apk"
keytool -genkeypair -keystore "$work/debug.jks" -storepass android -keypass android -alias fx -dname 'CN=otpanda wrapping-key fixture debug' -keyalg RSA -keysize 2048 -validity 2 >/dev/null 2>&1
"${bt}apksigner" sign --ks "$work/debug.jks" --ks-pass pass:android --key-pass pass:android --out "$work/fixture.apk" "$work/aligned.apk"
cp "$work/fixture.apk" "$out/fixture.apk"
actual=$(adb shell getprop ro.build.version.sdk | tr -d '\r\n')
[ "$actual" = "$EXPECT_API" ] || { echo "HARNESS FAIL: emulator API $actual != expected $EXPECT_API" >&2; exit 3; }
adb uninstall "$pkg" >/dev/null 2>&1 || true
adb install -t -r "$work/fixture.apk" > "$out/install.txt" 2>&1 || { cat "$out/install.txt" >&2; echo "HARNESS FAIL: install" >&2; exit 4; }
: > "$out/fixture.log"
for phase in $(python3 "$here/verify-log.py" --phases); do
  echo "== phase $phase" >> "$out/fixture.log"
  adb shell am instrument -w -e phase "$phase" "$pkg/.FixtureRunner" 2>&1 \
    | tee "$out/instrument-$phase.txt" | python3 "$here/extract-instrument.py" "$phase" "$EXPECT_API" >> "$out/fixture.log" || true
done
adb logcat -d -b crash 2>&1 | tr -d '\r' > "$out/logcat-crash.txt" || true
adb uninstall "$pkg" >/dev/null 2>&1 || true
cat "$out/fixture.log"
python3 "$here/verify-log.py" "$out/fixture.log" "$EXPECT_API"
