#!/usr/bin/env bash
# Signed-in shared-page acceptance on a device/emulator against the joined
# harness (same setup as tool/android-roundtrip.sh). Screenshots land in
# OUT/shots/*.png, extracted from the test log.
#
#   API_DIR=../api tool/android-signed-in-ui.sh [out-dir]
set -euo pipefail
API_DIR="${API_DIR:?path to the api repo checkout}"
OUT="${1:-signed-in-ui-out}"
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
set +e
flutter test integration_test/native_signed_in_ui_test.dart --flavor google -d "${DEVICE:-emulator-5554}" \
  --dart-define="HARNESS=http://127.0.0.1:$PORT" 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
python3 "$(dirname "$0")/extract-shots.py" "$OUT/test.log" "$OUT/shots"

exit "$result"
