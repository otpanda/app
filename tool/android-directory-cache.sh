#!/usr/bin/env bash
# Android acceptance for the cached 2FA Directory catalogue and logos: real
# path_provider cache directory, real network, then a cold directory from
# disk with the network blocked, the picker, and the bounds. Needs an
# emulator or device with internet. Screenshots land in OUT/shots/*.png.
#
#   tool/android-directory-cache.sh [out-dir]
set -euo pipefail
OUT="${1:-directory-cache-out}"
mkdir -p "$OUT"
set +e
timeout --signal=INT --kill-after=20s 600 flutter test --reporter expanded integration_test/service_directory_android_test.dart --flavor google -d "${DEVICE:-emulator-5554}" 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
adb logcat -d > "$OUT/logcat.txt" 2>&1 || true
adb shell dumpsys activity activities > "$OUT/activities.txt" 2>&1 || true
adb shell uiautomator dump /sdcard/cache-ui.xml > "$OUT/uiautomator.log" 2>&1 || true
adb pull /sdcard/cache-ui.xml "$OUT/ui.xml" >> "$OUT/uiautomator.log" 2>&1 || true
adb exec-out screencap -p > "$OUT/last-screen.png" 2>/dev/null || true
python3 "$(dirname "$0")/extract-shots.py" "$OUT/test.log" "$OUT/shots"
exit "$result"
