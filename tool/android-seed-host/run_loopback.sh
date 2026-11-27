#!/usr/bin/env bash
# Disposable emulator only. Real Flutter engine, production composition, synthetic owner, REAL API runtime on the host over adb reverse.
# Usage: OTPANDA_API_DIR=/path/to/api-checkout bash tool/android-seed-host/run_loopback.sh [out-dir]
# Host listener is 127.0.0.1 only (never 0.0.0.0); the emulator reaches it through `adb reverse`, not the 10.0.2.2 alias. Debug fixture only, in-memory state, no production resource.
set -euo pipefail
out=${1:-seed-host-loopback-out}; mkdir -p "$out"
api=${OTPANDA_API_DIR:?set OTPANDA_API_DIR to an API checkout containing tool/seed-sync-loopback/server.mjs}
port=8787
[ -f "$api/tool/seed-sync-loopback/server.mjs" ] || { echo 'HARNESS no loopback server in API checkout'; exit 2; }
[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r\n')" = 1 ] || { echo 'HARNESS non-emulator'; exit 2; }
python3 tool/android-seed-host/install.py
python3 tool/android-seed-host/install_loopback.py
flutter build apk --debug --flavor google -t tool/android-seed-host/fixture_loopback_main.dart --dart-define=LOOPBACK_BASE=http://127.0.0.1:$port > "$out/build.log" 2>&1
adb uninstall app.otpanda > "$out/uninstall-before.txt" 2>&1 || true
adb install -t build/app/outputs/flutter-apk/app-google-debug.apk > "$out/install.txt" 2>&1
# Derive assertion origin from the actual APK, not a guessed Gradle keystore path.
signer=$(find "${ANDROID_HOME:-$ANDROID_SDK_ROOT}/build-tools" -name apksigner -type f | sort -V | tail -1)
[ -n "$signer" ] || { echo "HARNESS apksigner unavailable"; exit 2; }
fp=$("$signer" verify --print-certs build/app/outputs/flutter-apk/app-google-debug.apk | sed -n 's/.*SHA-256 digest: *//p' | head -1 | tr -d '\r' | tr 'a-f' 'A-F' | sed 's/../&:/g;s/:$//')
printf '%s' "$fp" | grep -Eq '^([0-9A-F]{2}:){31}[0-9A-F]{2}$' || { echo 'HARNESS actual APK signer unavailable'; exit 2; }
echo 'signer_checked=yes-actual-apk' > "$out/signer.txt"
node "$api/tool/seed-sync-loopback/server.mjs" "$port" 127.0.0.1 "$fp" > "$out/host.log" 2>&1 &
host=$!
cleanup() { kill "$host" 2>/dev/null || true; adb reverse --remove tcp:$port > "$out/reverse-remove.txt" 2>&1 || true; adb uninstall app.otpanda > "$out/uninstall-after.txt" 2>&1 || true; }
trap cleanup EXIT
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$port/__loopback/state" > "$out/server-state-initial.json" 2>/dev/null && break; sleep 1; done
[ -s "$out/server-state-initial.json" ] || { echo 'HARNESS loopback host did not start'; exit 2; }
adb reverse tcp:$port tcp:$port
# Disposable launcher can ANR during first Google services startup. Reset only this test emulator launcher before collecting any app proof.
adb shell am force-stop com.google.android.apps.nexuslauncher
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb shell input keyevent KEYCODE_HOME
sleep 5
for phase in create restart; do
  adb shell am force-stop app.otpanda
  adb logcat -c
  adb shell am start -n app.otpanda/app.otpanda.seedfixture.SeedHostActivity --es phase "$phase" > "$out/start-$phase.txt"
  for i in $(seq 1 60); do
    adb logcat -d -s SEEDFX:I '*:S' > "$out/$phase.log"
    if grep -q 'CHECK phase_complete true' "$out/$phase.log"; then break; fi
    if grep -q 'CHECK .* false' "$out/$phase.log"; then break; fi
    sleep 1
  done
  sleep 2
  curl -fsS "http://127.0.0.1:$port/__loopback/state" > "$out/server-state-$phase.json" || echo '{}' > "$out/server-state-$phase.json"
  adb shell uiautomator dump /sdcard/seedfx-ui.xml > "$out/ui-dump-$phase.txt"
  adb pull /sdcard/seedfx-ui.xml "$out/ui-$phase.xml" > "$out/ui-pull-$phase.txt" 2>&1
  adb exec-out screencap -p > "$out/$phase.png"
  adb logcat -d -b crash > "$out/crash-$phase.txt"
done
python3 tool/android-seed-host/verify_loopback.py "$out"
