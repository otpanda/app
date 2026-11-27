#!/usr/bin/env bash
# Disposable emulator only. Real Flutter engine, production composition, synthetic owner.
set -euo pipefail
out=${1:-seed-host-out}; mkdir -p "$out"
[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r\n')" = 1 ] || { echo 'HARNESS non-emulator'; exit 2; }
python3 tool/android-seed-host/install.py
flutter build apk --debug --flavor google -t tool/android-seed-host/fixture_main.dart > "$out/build.log" 2>&1
adb uninstall app.otpanda > "$out/uninstall-before.txt" 2>&1 || true
adb install -t build/app/outputs/flutter-apk/app-google-debug.apk > "$out/install.txt" 2>&1
trap 'adb uninstall app.otpanda > "$out/uninstall-after.txt" 2>&1 || true' EXIT
for phase in create restart; do
  adb shell am force-stop app.otpanda
  adb logcat -c
  adb shell am start -n app.otpanda/app.otpanda.seedfixture.SeedHostActivity --es phase "$phase" > "$out/start-$phase.txt"
  for i in $(seq 1 40); do
    adb logcat -d -s SEEDFX:I '*:S' > "$out/$phase.log"
    if grep -q 'CHECK phase_complete true' "$out/$phase.log"; then break; fi
    if grep -q 'CHECK .* false' "$out/$phase.log"; then break; fi
    sleep 1
  done
  adb exec-out screencap -p > "$out/$phase.png"
  adb logcat -d -b crash > "$out/crash-$phase.txt"
done
python3 tool/android-seed-host/verify.py "$out"
