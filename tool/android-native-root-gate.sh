#!/usr/bin/env bash
# DEBUG/QUALIFICATION ONLY, UNRUN until an emulator executes it. Disposable emulator only (refuses anything else).
# Installed real-root gate: integration_test/native_root_gate_test.dart against the real API runtime on the host (tool/seed-sync-loopback/server.mjs).
#   OTPANDA_API_DIR=/path/to/api bash tool/android-native-root-gate.sh [out-dir]
# Sets a throwaway device PIN so the real BiometricPrompt device-credential prompt can be answered by a responder; clears it on exit. Pass/fail comes from the
# test exit code AND the required GATE:<name> lines in the log, never from the responder.
set -euo pipefail
OUT="${1:-native-root-gate-out}"; mkdir -p "$OUT"
API="${OTPANDA_API_DIR:?set OTPANDA_API_DIR to an API checkout containing tool/seed-sync-loopback/server.mjs}"
PORT=8787; PIN=482913
DEV="${DEVICE:-emulator-5554}"; A=(adb -s "$DEV")
[ -f "$API/tool/seed-sync-loopback/server.mjs" ] || { echo 'HARNESS no loopback server in API checkout'; exit 2; }
[ "$("${A[@]}" shell getprop ro.kernel.qemu | tr -d '\r\n')" = 1 ] || { echo 'HARNESS refusing non-emulator'; exit 2; }
python3 tool/android-seed-host/install_loopback.py
"${A[@]}" uninstall app.otpanda > "$OUT/uninstall-before.txt" 2>&1 || true
# Build with the same target/flavor before deriving the actual signing certificate.
flutter build apk --debug --flavor google -t integration_test/native_root_gate_test.dart --dart-define="OTPANDA_API_ORIGIN=http://127.0.0.1:$PORT" --dart-define="HARNESS=http://127.0.0.1:$PORT" --dart-define=NATIVE_SEED_SYNC_ENABLED=true > "$OUT/build.log" 2>&1
signer=$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}/build-tools" -name apksigner -type f | sort -V | tail -1)
[ -n "$signer" ] || { echo 'HARNESS apksigner unavailable'; exit 2; }
fp=$("$signer" verify --print-certs build/app/outputs/flutter-apk/app-google-debug.apk | sed -n 's/.*SHA-256 digest: *//p' | head -1 | tr -d '\r' | tr 'a-f' 'A-F' | sed 's/../&:/g;s/:$//')
printf '%s' "$fp" | grep -Eq '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' || { echo 'HARNESS actual APK signer unavailable'; exit 2; }
LOOPBACK_LOG=1 node "$API/tool/seed-sync-loopback/server.mjs" "$PORT" 127.0.0.1 "$fp" > "$OUT/host.log" 2>&1 &
HOST=$!; RESP=
cleanup() {
  [ -z "$RESP" ] || kill "$RESP" 2>/dev/null || true
  kill "$HOST" 2>/dev/null || true
  "${A[@]}" reverse --remove "tcp:$PORT" > "$OUT/reverse-remove.txt" 2>&1 || true
  "${A[@]}" shell locksettings clear --old "$PIN" > "$OUT/pin-clear.txt" 2>&1 || true
  "${A[@]}" uninstall app.otpanda > "$OUT/uninstall-after.txt" 2>&1 || true
}
trap cleanup EXIT
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$PORT/__loopback/counters" > "$OUT/counters-initial.json" 2>/dev/null && break; sleep 1; done
[ -s "$OUT/counters-initial.json" ] || { echo 'HARNESS loopback host did not start'; exit 2; }
"${A[@]}" reverse "tcp:$PORT" "tcp:$PORT"
"${A[@]}" shell am force-stop com.google.android.apps.nexuslauncher
"${A[@]}" shell input keyevent KEYCODE_WAKEUP; "${A[@]}" shell wm dismiss-keyguard
"${A[@]}" shell locksettings set-pin "$PIN" > "$OUT/pin-set.txt" 2>&1 || { cat "$OUT/pin-set.txt"; echo 'HARNESS cannot set throwaway PIN'; exit 2; }
# Responder: when the real credential prompt is on screen, type the PIN. It only reacts to the OTPanda prompt title or the system PIN entry field.
( n=0; while true; do
    "${A[@]}" shell uiautomator dump /sdcard/gate-ui.xml > "$OUT/responder-adb.txt" 2>&1 && "${A[@]}" pull /sdcard/gate-ui.xml "$OUT/gate-ui-last.xml" > "$OUT/responder-adb.txt" 2>&1 || true
    if grep -q -e 'Unlock OTPanda' -e 'lockPassword' -e 'passwordEntry' "$OUT/gate-ui-last.xml" 2>/dev/null; then
      n=$((n+1)); cp "$OUT/gate-ui-last.xml" "$OUT/prompt-$n.xml"
      "${A[@]}" shell input text "$PIN"; "${A[@]}" shell input keyevent KEYCODE_ENTER
      echo "RESPONDED $n" >> "$OUT/responder.log"; sleep 4
    fi
    : > "$OUT/gate-ui-last.xml"; sleep 1
  done ) &
RESP=$!
set +e
flutter test integration_test/native_root_gate_test.dart --flavor google -d "$DEV" \
  --dart-define="OTPANDA_API_ORIGIN=http://127.0.0.1:$PORT" --dart-define="HARNESS=http://127.0.0.1:$PORT" --dart-define=NATIVE_SEED_SYNC_ENABLED=true 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
mkdir -p "$OUT/shots"
python3 tool/extract-shots.py "$OUT/test.log" "$OUT/shots"
curl -fsS "http://127.0.0.1:$PORT/__loopback/counters" > "$OUT/counters-final.json" || true
"${A[@]}" exec-out screencap -p > "$OUT/final.png" || true
"${A[@]}" logcat -d -b crash > "$OUT/crash.txt" || true
need="session_enrolled device_lock_enabled locked_no_owner_read_no_admission admitted_after_owner_and_unlock root_enrollment_confirmed lock_hides_immediately root_downloaded_offline_totp cold_local_view_offline_after_unlock paused_offline_reopened lock_disabled_paused_offline_rfc signout_invalidated_cold_selection cold_root_after_signout_no_local_view complete"
missing=0
for g in $need; do grep -q "GATE:$g" "$OUT/test.log" || { echo "MISSING GATE:$g"; missing=1; }; done
[ "$result" -eq 0 ] && [ "$missing" -eq 0 ] || { echo "FAIL result=$result missing=$missing"; exit 1; }
echo 'PASS all gates'
