#!/usr/bin/env bash
# Runs INSIDE the emulator (android-emulator-runner). Real emulator, real app
# process, real adb screenshot. It proves only: the debug APK installs, starts,
# does not crash, and shows the native signed-out sign-in screen. It is not
# Keystore/passkey/Google/camera proof and does not sign in.
set -euo pipefail
APK="${1:?apk path}"
OUT="${2:-smoke-out}"
PKG=app.otpanda
mkdir -p "$OUT"
adb install -r "$APK"
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
ok=0
for i in $(seq 1 30); do
  sleep 3
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  adb pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null 2>&1 || true
  if [ -s "$OUT/ui.xml" ] && grep -q "Continue with Google" "$OUT/ui.xml" && grep -q "Sign in with a passkey" "$OUT/ui.xml" && ! grep -q "Sign in with browser" "$OUT/ui.xml"; then ok=1; break; fi
done
adb exec-out screencap -p > "$OUT/screen.png"
adb logcat -d > "$OUT/logcat.txt" || true
adb shell pidof "$PKG" > "$OUT/pid.txt" || true
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then echo "crash in logcat"; grep -n -A12 "FATAL EXCEPTION" "$OUT/logcat.txt" | head -40; exit 1; fi
[ -s "$OUT/pid.txt" ] || { echo "app process not running"; exit 1; }
[ "$ok" = 1 ] || { echo "signed-out screen text not found in UI dump"; exit 1; }
echo "smoke ok"
