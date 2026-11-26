#!/usr/bin/env bash
# Real native root (buildNativeRoot) acceptance on a device/emulator against the joined
# harness (same setup as tool/android-roundtrip.sh). Screenshots land in
# OUT/shots/*.png, extracted from the test log.
#
#   API_DIR=../api tool/android-native-root.sh [out-dir]
set -euo pipefail
API_DIR="${API_DIR:?path to the api repo checkout}"
OUT="${1:-native-root-out}"
PORT="${PORT:-8787}"
mkdir -p "$OUT"
( cd "$API_DIR" && npm ci --no-audit --no-fund )
( cd "$API_DIR" && node tool/native-roundtrip-harness.mjs --port "$PORT" ) > "$OUT/harness.log" 2>&1 &
H=$!
trap 'kill $H 2>/dev/null || true; adb reverse --remove "tcp:$PORT" 2>/dev/null || true' EXIT
for i in $(seq 1 60); do
  grep -q '^READY' "$OUT/harness.log" 2>/dev/null && break
  kill -0 "$H" 2>/dev/null || { echo "harness exited"; cat "$OUT/harness.log"; exit 1; }
  sleep 2
done
grep -q '^READY' "$OUT/harness.log" || { echo "harness not ready"; exit 1; }
adb reverse "tcp:$PORT" "tcp:$PORT"
mkdir -p "$OUT/shots"
( for state in revoked cold; do
    for i in $(seq 1 360); do
      if grep -q "ADB-SHOT-READY:$state" "$OUT/test.log" 2>/dev/null; then
        adb exec-out screencap -p > "$OUT/shots/$state.png"
        break
      fi
      sleep 1
    done
  done ) &
WATCH=$!
set +e
flutter test integration_test/native_root_acceptance_test.dart --flavor google --dart-define=NATIVE_SIGNIN=true --dart-define="OTPANDA_API_ORIGIN=http://127.0.0.1:$PORT" -d "${DEVICE:-emulator-5554}" \
  --dart-define="HARNESS=http://127.0.0.1:$PORT" 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
kill "$WATCH" 2>/dev/null || true
wait "$WATCH" 2>/dev/null || true
python3 "$(dirname "$0")/extract-shots.py" "$OUT/test.log" "$OUT/shots"

exit "$result"
