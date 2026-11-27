#!/usr/bin/env bash
# Disposable emulator only. Real Flutter engine, production ImportPickerHost, REAL system document picker, synthetic provider.
set -euo pipefail
out=${1:-picker-out}; mkdir -p "$out"
q=tool/android-import-picker/qualification
[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r\n')" = 1 ] || { echo 'HARNESS non-emulator'; exit 2; }
[ "$(adb shell getprop ro.build.version.sdk | tr -d '\r\n')" = 34 ] || { echo 'HARNESS expected API 34'; exit 2; }
python3 tool/android_import_picker_overlay.py
python3 $q/install.py
flutter build apk --debug --flavor google -t $q/fixture_main.dart > "$out/build.log" 2>&1
adb uninstall app.otpanda > "$out/uninstall-before.txt" 2>&1 || true
adb install -t build/app/outputs/flutter-apk/app-google-debug.apk > "$out/install.txt" 2>&1
cleanup() {
  adb shell settings put global always_finish_activities 0 || true
  adb shell settings put system user_rotation 0 || true
  adb shell settings put system accelerometer_rotation 1 || true
  adb shell settings put system font_scale 1.0 || true
  adb uninstall app.otpanda > "$out/uninstall-after.txt" 2>&1 || true
}
trap cleanup EXIT
adb shell am force-stop com.google.android.apps.nexuslauncher
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb shell input keyevent KEYCODE_HOME
sleep 5
set +e
python3 $q/drive.py "$out"; drive_rc=$?
set -e
# Evidence for the verifier even when the harness stopped early: a missing scenario file fails verification loudly.
python3 $q/verify.py "$out"
exit $drive_rc
