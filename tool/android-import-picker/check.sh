#!/usr/bin/env bash
set -euo pipefail
# JVM tests for the Android import picker core against fake streams, plus compile checks when ANDROID_JAR / FLUTTER_EMBEDDING_JAR are set.
# Not evidence of the real system picker, a real content provider, or an installed app.
: "${KOTLIN_LIB:?Set KOTLIN_LIB to Kotlin 2.0.20 compiler jars}"
root=$(cd "$(dirname "$0")" && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
compile(){ java -cp "$KOTLIN_LIB/*" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -classpath "$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar${1:+:$1}" -d "$2" "${@:3}"; }
compile '' "$out/t" "$root/DocumentImport.kt" "$root/DocumentImportTest.kt"
java -cp "$out/t:$KOTLIN_LIB/kotlin-stdlib-2.0.20.jar" org.otpanda.documentimport.DocumentImportTestKt
if [ -n "${ANDROID_JAR:-}" ] && [ -n "${FLUTTER_EMBEDDING_JAR:-}" ]; then
  compile "$ANDROID_JAR:$FLUTTER_EMBEDDING_JAR" "$out/host" "$root/DocumentImport.kt" "$root/host/ImportPickerHost.kt"
  printf '%s\n' 'PASS host compiles against android.jar and the Flutter embedding jar (API surface only)'
fi
# Production code must not log, persist a URI grant, or reference the test hook's stand-ins.
if grep -nE 'Log\.|println|takePersistableUriPermission|SharedPreferences|FileOutputStream|openFileOutput' "$root/DocumentImport.kt" "$root/host/ImportPickerHost.kt"; then echo 'FAIL production source logs or persists' >&2; exit 1; fi
if grep -lE 'Tracked|Blocking|Failing|Trickle' "$root/DocumentImport.kt" "$root/host/ImportPickerHost.kt"; then echo 'FAIL test stand-in referenced from production source' >&2; exit 1; fi
python3 "$root/../android_import_picker_overlay_test.py"
