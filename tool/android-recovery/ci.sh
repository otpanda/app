#!/usr/bin/env bash
# Reproducible runner for the inactive native recovery source: JVM protocol and
# metadata tests plus an Android API 35 compile. It downloads hash-pinned
# toolchains, runs check.sh, and proves nothing about devices, OS credential UI,
# Keystore behavior, lifecycle, backup or release signing identity.
set -euo pipefail
KOTLIN_URL='https://github.com/JetBrains/kotlin/releases/download/v2.0.20/kotlin-compiler-2.0.20.zip'
KOTLIN_SHA256='5f5d2a8ad6a718a002acd0775b67a9e27035872fdbd4b0791e3cb3ea00095931'
PLATFORM_URL='https://dl.google.com/android/repository/platform-35_r02.zip'
PLATFORM_SHA256='0988cacad01b38a18a47bac14a0695f246bc76c1b06c0eeb8eb0dc825ab0c8e0'
root=$(cd "$(dirname "$0")" && pwd)
work=${NATIVE_CI_DIR:-$(mktemp -d)}
[ -n "${NATIVE_CI_DIR:-}" ] && mkdir -p "$work"
[ -n "${NATIVE_CI_DIR:-}" ] || trap 'rm -rf "$work"' EXIT
fetch(){ # url sha256 file
  if [ ! -f "$3" ] || ! echo "$2  $3" | sha256sum -c --status; then
    curl --fail --silent --show-error --location --retry 3 --output "$3" "$1"
  fi
  echo "$2  $3" | sha256sum -c --quiet
}
cd "$work"
fetch "$KOTLIN_URL" "$KOTLIN_SHA256" kotlin.zip
fetch "$PLATFORM_URL" "$PLATFORM_SHA256" platform.zip
rm -rf kotlinc android-35 lib
unzip -q kotlin.zip
unzip -q platform.zip 'android-35/android.jar'
# check.sh expects the Maven-style stdlib name beside the compiler jars.
mkdir lib
cp kotlinc/lib/*.jar lib/
cp kotlinc/lib/kotlin-stdlib.jar lib/kotlin-stdlib-2.0.20.jar
export KOTLIN_LIB="$work/lib" ANDROID_JAR="$work/android-35/android.jar"
bash "$root/check.sh"
