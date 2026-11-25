#!/usr/bin/env bash
# Joined acceptance: real AndroidKeystore + NativeAuth -> real auth-only Worker
# on real D1 (Miniflare), synthetic account only. Run with an emulator or
# device attached (adb). Needs a checkout of the API repo with the harness
# (tool/native-roundtrip-harness.mjs) and Node >= 22.
#
#   API_DIR=../api tool/android-roundtrip.sh [out-dir]
set -euo pipefail
API_DIR="${API_DIR:?path to the api repo checkout}"
OUT="${1:-roundtrip-out}"
PORT="${PORT:-8787}"
mkdir -p "$OUT"
# miniflare and esbuild come with the repo's pinned wrangler (npm ci).
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
flutter test integration_test/native_roundtrip_test.dart --flavor google -d emulator-5554 \
  --dart-define="HARNESS=http://127.0.0.1:$PORT" 2>&1 | tee "$OUT/test.log"
