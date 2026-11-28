#!/usr/bin/env bash
set -euo pipefail
out=${1:-import-native-out};mkdir -p "$out"
q=tool/android-import-picker/qualification
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r\n')" == 1 ]] || exit 2
[[ "$(adb shell getprop ro.build.version.sdk | tr -d '\r\n')" == 34 ]] || exit 2
python3 "$q/check_hosts.py" "$out/host-digests.json"
python3 "$q/install.py"
flutter build apk --debug --flavor google -t "$q/fixture_main.dart" > "$out/build.log" 2>&1
adb install -t build/app/outputs/flutter-apk/app-google-debug.apk > "$out/install.txt" 2>&1
trap 'adb uninstall app.otpanda.importfixture || true' EXIT
# Actual journal filesystem tests, then a hard process boundary after durable pending claim.
run_journal() (
set -e
for phase in checks prepare resume;do
 adb shell am force-stop app.otpanda.importfixture
 adb logcat -c
 adb shell am start -n app.otpanda.importfixture/app.otpanda.pickerfx.JournalFixtureActivity --es phase "$phase"
 for i in $(seq 1 40);do adb logcat -d -s JOURNALFX:I '*:S' > "$out/journal-$phase.log";grep -q 'PASS complete\|FAIL' "$out/journal-$phase.log" && break;sleep 1;done
 cat "$out/journal-$phase.log"
 grep -q 'PASS complete' "$out/journal-$phase.log"
 if grep -q 'FAIL' "$out/journal-$phase.log";then exit 1;fi
 if [[ "$phase" == prepare ]];then
  pid=$(adb shell pidof app.otpanda.importfixture | tr -d '\r');[[ -n "$pid" ]]
  adb shell run-as app.otpanda.importfixture kill -9 "$pid"
  sleep 2
  [[ -z "$(adb shell pidof app.otpanda.importfixture | tr -d '\r')" ]]
 fi
done
)
set +e
run_journal; journal_rc=$?
python3 "$q/drive.py" "$out"; picker_drive_rc=$?
python3 "$q/verify.py" "$out"; picker_verify_rc=$?
set -e
printf 'journal=%s picker_drive=%s picker_verify=%s\n' "$journal_rc" "$picker_drive_rc" "$picker_verify_rc" > "$out/suite-status.txt"
[[ "$journal_rc" == 0 && "$picker_drive_rc" == 0 && "$picker_verify_rc" == 0 ]]
