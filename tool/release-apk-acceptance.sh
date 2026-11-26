#!/usr/bin/env bash
set -euo pipefail
apk="candidate/otpanda-android-google-${GITHUB_REF_NAME}.apk"
for source in original-alpha6/otpanda-android-google-native-candidate.apk broken-alpha7.apk;do
 name=$(basename "$source" .apk)
 adb uninstall app.otpanda || true
 adb install "$source" 2>&1 | tee "repair-out/$name-initial.txt"
 adb shell dumpsys package app.otpanda > "repair-out/$name-before.txt"
 adb install -r "$apk" 2>&1 | tee "repair-out/$name-upgrade.txt"
 adb shell dumpsys package app.otpanda > "repair-out/$name-after.txt"
 adb shell am start -n app.otpanda/.MainActivity
 for i in $(seq 1 20);do
  sleep 2
  adb shell uiautomator dump /sdcard/release.xml || true
  adb pull /sdcard/release.xml repair-out/current.xml || true
  if grep -q 'Continue with Google' repair-out/current.xml;then break;fi
 done
 cp repair-out/current.xml "repair-out/$name-signin.xml"
 adb exec-out screencap -p > "repair-out/$name-signin.png"
 if grep -q 'Sign-in on this device is not ready' repair-out/current.xml;then exit 1;fi
 grep -q 'Continue with Google' repair-out/current.xml
 adb shell am force-stop app.otpanda
 done
sha256sum "$apk" > repair-out/exact-installed-apk-sha256.txt
