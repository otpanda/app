#!/usr/bin/env bash
# Installed private Assign/Resume against a synthetic real Worker/D1 harness.
# API_DIR=../api tool/android-rules-private.sh [out-dir]
set -euo pipefail
API_DIR="${API_DIR:?path to the api repo checkout}"
OUT="${1:-signed-in-ui-out}"
PORT="${PORT:-8787}"
mkdir -p "$OUT"
( cd "$API_DIR" && npm ci --no-audit --no-fund )
( cd "$API_DIR" && node tool/rules-native-harness.mjs --port "$PORT" ) > "$OUT/harness.log" 2>&1 &
H=$!
trap 'kill $H 2>/dev/null || true; adb reverse --remove "tcp:$PORT" 2>/dev/null || true' EXIT
for i in $(seq 1 60); do
  grep -q '^READY' "$OUT/harness.log" 2>/dev/null && break
  kill -0 "$H" 2>/dev/null || { echo "harness exited"; cat "$OUT/harness.log"; exit 1; }
  sleep 2
done
grep -q '^READY' "$OUT/harness.log" || { echo "harness not ready"; exit 1; }
adb reverse "tcp:$PORT" "tcp:$PORT"
set +e
flutter test integration_test/native_rules_private_test.dart --flavor google -d "${DEVICE:-emulator-5554}" \
  --dart-define="HARNESS=http://127.0.0.1:$PORT" 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
python3 "$(dirname "$0")/extract-shots.py" "$OUT/test.log" "$OUT/shots"

exit "$result"
