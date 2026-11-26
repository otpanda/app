#!/usr/bin/env bash
set -euo pipefail
APK="$1";OUT="$2";mkdir -p "$OUT"
adb install -r "$APK" | tee "$OUT/install.log"
adb shell input keyevent KEYCODE_HOME
sleep 3
# Pixel launcher all-apps grid renders the package's actual adaptive icon.
adb shell input swipe 540 1800 540 350 500
sleep 3
adb exec-out screencap -p > "$OUT/installed-launcher-all-apps.png"
adb shell uiautomator dump /sdcard/launcher-proof.xml
adb pull /sdcard/launcher-proof.xml "$OUT/launcher-proof.xml"
adb shell dumpsys package app.otpanda > "$OUT/package.txt"
grep -q OTPanda "$OUT/launcher-proof.xml"
