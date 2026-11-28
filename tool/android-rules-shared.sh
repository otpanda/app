#!/usr/bin/env bash
set -euo pipefail
API_DIR="${API_DIR:?exact API fixture source required}"
OUT="${1:-native-shared-rules-out}"
mkdir -p "$OUT"
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || { echo 'Refusing non-emulator'; exit 1; }
adb shell locksettings set-pin 864291
adb shell locksettings verify --old 864291
adb shell input keyevent KEYCODE_WAKEUP
adb shell input keyevent 82
( cd "$API_DIR" && npm ci --no-audit --no-fund && node tool/rules-native-harness.mjs --port 8787 ) > "$OUT/harness.log" 2>&1 & H=$!
python3 tool/shared-rule-os-unlock.py "$OUT" > "$OUT/os-driver.log" 2>&1 & U=$!
trap 'touch "$OUT/stop-os-driver"; kill "$H" "$U" 2>/dev/null || true; wait "$H" "$U" 2>/dev/null || true; adb reverse --remove tcp:8787' EXIT
for i in $(seq 1 80); do grep -q '^READY' "$OUT/harness.log" && break; sleep 2; done
grep -q '^READY' "$OUT/harness.log"
adb reverse tcp:8787 tcp:8787
set +e
flutter test integration_test/native_rules_private_test.dart --flavor google -d emulator-5554 --dart-define=SHARED_RULES=true --dart-define=HARNESS=http://127.0.0.1:8787 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
python3 tool/extract-shots.py "$OUT/test.log" "$OUT/shots"
exit "$result"
