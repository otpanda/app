#!/usr/bin/env bash
set -euo pipefail
: "${KOTLIN_LIB:?Set KOTLIN_LIB to Kotlin2.0.20 compiler jars}"
root=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" -d "$out/classes" "$root/TotpCalculator.kt" "$root/TotpCalculatorTest.kt"
java -cp "$out/classes:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.totp.TotpCalculatorTestKt
