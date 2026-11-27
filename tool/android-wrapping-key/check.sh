#!/usr/bin/env bash
set -euo pipefail
# JVM tests for the Android wrapping-key core against software fakes, plus a compile of the Keystore wrapper when ANDROID_JAR is set.
# Not evidence of real Keystore, locked-device, backup, fsync or uninstall behavior.
: "${KOTLIN_LIB:?Set KOTLIN_LIB to Kotlin2.0.20 compiler jars}"
root=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
compile(){ java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar${1:+:$1}" -d "$2" "${@:3}"; }
compile '' "$out/t" "$root/WrappingKey.kt" "$root/WrappingKeyChannel.kt" "$root/WrappingKeyTestSupport.kt" "$root/WrappingKeyChild.kt" "$root/WrappingKeyTest.kt"
java -cp "$out/t:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.wrappingkey.WrappingKeyTestKt
if [ -n "${ANDROID_JAR:-}" ]; then
  compile "$ANDROID_JAR" "$out/android" "$root/WrappingKey.kt" "$root/WrappingKeyChannel.kt" "$root/WrappingKeyAndroid.kt"
  printf '%s\n' 'PASS Android Keystore wrapper compiles against android.jar (compile-time API surface only; the host file needs the Flutter embedding and is compiled by the app build)'
  if [ -n "${ANDROID_JAR_API30:-}" ]; then
    compile "$ANDROID_JAR_API30" "$out/android30" "$root/WrappingKey.kt" "$root/WrappingKeyChannel.kt" "$root/WrappingKeyAndroid.kt"
    printf '%s\n' 'PASS wrapper compiles against API 30 android.jar'
  fi
fi
# Production code must not contain the test stand-ins.
if grep -lE 'FakeKeystore|RecordingSync' "$root/WrappingKey.kt" "$root/WrappingKeyChannel.kt" "$root/WrappingKeyAndroid.kt" "$root/host/WrappingKeyHost.kt"; then echo 'FAIL test stand-in referenced from production source' >&2; exit 1; fi
# deleteEntry may appear only inside deleteKey (the explicit purge); ensureKey and every error path must never delete an alias.
if [ "$(grep -c 'deleteEntry' "$root/WrappingKeyAndroid.kt")" != 1 ] || ! grep -q 'override fun deleteKey().*deleteEntry' "$root/WrappingKeyAndroid.kt"; then echo 'FAIL deleteEntry outside deleteKey' >&2; exit 1; fi
python3 "$root/../android_wrapping_key_overlay_test.py"
