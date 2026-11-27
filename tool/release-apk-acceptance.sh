#!/usr/bin/env bash
set -euo pipefail
adb root
adb wait-for-device
mkdir -p repair-out
printf '%s\n' '8f150b01fcf3e17acb98584fbe36df1eafa85c1d1cdb375b551e3a602006d228  original-alpha6/otpanda-android-google-native-candidate.apk' 'cacc2ec1339e9727f11fa7d2c2bce3134de8c0cda33a4208e11d46a6a61939c4  original-alpha6/otpanda-android-fdroid-native-candidate.apk' '2b13c054117ecbe54d87e08d759ebb8f01534c3a8ecde50444034e5bc8aad771  broken-alpha7.apk' | sha256sum -c - | tee repair-out/pinned-fixtures.txt
sign_in(){
 local name="$1"
 adb shell am force-stop app.otpanda
 adb shell am start -n app.otpanda/.MainActivity
 local ready=false
 for i in $(seq 1 25);do
  sleep 2
  rm -f repair-out/current.xml
  adb shell rm -f /sdcard/release.xml
  if adb shell uiautomator dump /sdcard/release.xml && adb pull /sdcard/release.xml repair-out/current.xml;then
   # A known disposable-emulator Launcher ANR is not an app failure. Close only
   # that identified system dialog, preserve its evidence, then retry the UI read.
   if python3 tool/close-launcher-anr.py repair-out/current.xml "$name" "$i"; then
    continue
   fi
   if grep -q 'Sign-in on this device is not ready' repair-out/current.xml;then break;fi
   if grep -q 'Sign in with a passkey' repair-out/current.xml && grep -q 'Create account with a passkey' repair-out/current.xml;then ready=true;break;fi
  fi
 done
 adb exec-out screencap -p > "repair-out/$name-signin.png"
 test -f repair-out/current.xml && cp repair-out/current.xml "repair-out/$name-signin.xml"
 if grep -Eq 'Sign-in on this device is not ready|Open OTPanda in your browser|This development build cannot sign in' repair-out/current.xml;then return 1;fi
 test "$ready" = true
}
# Negative control must reject the exact disabled alpha7, not stale UI.
adb uninstall app.otpanda || true
adb install broken-alpha7.apk | tee repair-out/negative-install.txt
grep -q '^Success' repair-out/negative-install.txt
if sign_in negative-alpha7;then echo 'ERROR negative control passed';exit 1;fi
grep -q 'Sign-in on this device is not ready' repair-out/negative-alpha7-signin.xml
printf '%s\n' 'PASS negative control rejected disabled alpha7' > repair-out/negative-control.txt
for flavor in google fdroid;do
 apk="candidate/otpanda-android-$flavor-${GITHUB_REF_NAME}.apk"
 for source in "original-alpha6/otpanda-android-$flavor-native-candidate.apk" broken-alpha7.apk;do
  name="$flavor-$(basename "$source" .apk)"
  adb uninstall app.otpanda || true
  adb install "$source" 2>&1 | tee "repair-out/$name-initial.txt"
  grep -q '^Success' "repair-out/$name-initial.txt"
  adb shell dumpsys package app.otpanda > "repair-out/$name-before.txt"
  adb shell 'mkdir -p /data/user/0/app.otpanda/files; echo otpanda-synthetic-upgrade-sentinel > /data/user/0/app.otpanda/files/upgrade-proof'
  before=$(adb shell dumpsys package app.otpanda | grep 'firstInstallTime=' | head -1)
  adb install -r "$apk" 2>&1 | tee "repair-out/$name-upgrade.txt"
  grep -q '^Success' "repair-out/$name-upgrade.txt"
  adb shell dumpsys package app.otpanda > "repair-out/$name-after.txt"
  old_code=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' "repair-out/$name-before.txt" | head -1)
  new_code=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' "repair-out/$name-after.txt" | head -1)
  test "$new_code" -gt "$old_code"
  test "$new_code" -gt 2026112605
  grep -Eq "^[[:space:]]*versionName=${GITHUB_REF_NAME#v}$" "repair-out/$name-after.txt"
  after=$(adb shell dumpsys package app.otpanda | grep 'firstInstallTime=' | head -1)
  test "$before" = "$after"
  adb shell cat /data/user/0/app.otpanda/files/upgrade-proof | tee "repair-out/$name-preserved-data.txt"
  grep -q 'otpanda-synthetic-upgrade-sentinel' "repair-out/$name-preserved-data.txt"
  sign_in "$name"
 done
 if [ "$flavor" = google ];then
  grep -q 'Continue with Google' "repair-out/$name-signin.xml"
 fi
 sha256sum "$apk" >> repair-out/exact-installed-apk-sha256.txt
done
