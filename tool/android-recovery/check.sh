#!/usr/bin/env bash
set -euo pipefail
: "${KOTLIN_LIB:?Set KOTLIN_LIB to the compiler library directory}"
: "${ANDROID_JAR:?Set ANDROID_JAR to Android platform android.jar}"
root=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
compile(){ java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar${1:+:$1}" -d "$out/classes" "${@:2}"; }
compile '' "$root/DeviceProof.kt" "$root/DeviceProofTest.kt" "$root/EnrollmentRecord.kt" "$root/EnrollmentRecordTest.kt"
java -cp "$out/classes:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.recovery.DeviceProofTestKt "$root/fixtures/device-proof-vector.txt"
java -cp "$out/classes:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.recovery.EnrollmentRecordTestKt
compile "$ANDROID_JAR" "$root/DeviceProof.kt" "$root/DeviceProofError.kt" "$root/NoBackupPendingStore.kt" "$root/DurableDeviceKey.kt" "$root/ActivityProofOperation.kt" "$root/EnrollmentRecord.kt" "$root/NoBackupEnrollmentStore.kt"
printf '%s\n' 'PASS inactive Android primitive compiles; OS/Keystore lifecycle behavior remains unverified'
