#!/usr/bin/env bash
set -euo pipefail
adb root
adb wait-for-device
mkdir -p repair-out
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
   if grep -q 'Sign-in on this device is not ready' repair-out/current.xml;then break;fi
   if grep -q 'Continue with Google' repair-out/current.xml;then ready=true;break;fi
  fi
 done
 adb exec-out screencap -p > "repair-out/$name-signin.png"
 test -f repair-out/current.xml && cp repair-out/current.xml "repair-out/$name-signin.xml"
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
  after=$(adb shell dumpsys package app.otpanda | grep 'firstInstallTime=' | head -1)
  test "$before" = "$after"
  adb shell cat /data/user/0/app.otpanda/files/upgrade-proof | tee "repair-out/$name-preserved-data.txt"
  grep -q 'otpanda-synthetic-upgrade-sentinel' "repair-out/$name-preserved-data.txt"
  sign_in "$name"
 done
 sha256sum "$apk" >> repair-out/exact-installed-apk-sha256.txt
done
