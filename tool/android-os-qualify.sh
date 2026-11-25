#!/usr/bin/env bash
# Runs the OS qualification on a running emulator or device (adb device
# attached). Real AndroidKeystore and Credential Manager, no server, no
# account. A background loop presses BACK so a system credential sheet is
# dismissed as a user cancel. Output: the test log plus a screenshot taken
# while the sheet is up.
set -euo pipefail
OUT="${1:-os-qualify-out}"
mkdir -p "$OUT"
( for i in $(seq 1 600); do
    sleep 3
    if adb shell dumpsys window 2>/dev/null | grep -q -i -E "credential|password|accountselector"; then
      adb exec-out screencap -p > "$OUT/sheet.png" || true
      adb shell input keyevent KEYCODE_BACK
    fi
  done ) &
BG=$!
trap 'kill $BG 2>/dev/null || true' EXIT
flutter test integration_test/native_os_qualification_test.dart --flavor google -d emulator-5554 \
  --dart-define=NATIVE_SIGNIN=true --dart-define=OS_SHEET=true 2>&1 | tee "$OUT/test.log"
grep -E "PASSKEY_AVAILABLE=|SHEET_OUTCOME=" "$OUT/test.log" || true
