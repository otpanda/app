#!/usr/bin/env bash
set -euo pipefail
for old in 5 6;do
 adb uninstall app.otpanda || true
 adb install "apks/alpha$old.apk" 2>&1 | tee "upgrade-out/install-alpha$old.txt"
 adb shell am start -n app.otpanda/.MainActivity
 sleep 10
 adb shell dumpsys package app.otpanda > "upgrade-out/package-before-$old.txt"
 adb install -r apks/alpha7.apk 2>&1 | tee "upgrade-out/upgrade-$old-to7.txt"
 adb shell dumpsys package app.otpanda > "upgrade-out/package-after-$old.txt"
 adb shell am start -n app.otpanda/.MainActivity
 sleep 5
 adb exec-out screencap -p > "upgrade-out/upgraded-$old-to7.png"
 adb logcat -d > "upgrade-out/logcat-$old-to7.txt"
done

adb uninstall app.otpanda || true
adb install original-alpha6/otpanda-android-google-native-candidate.apk 2>&1 | tee upgrade-out/install-original-alpha6.txt
adb install -r apks/alpha7.apk 2>&1 | tee upgrade-out/original-alpha6-to-alpha7-rejection.txt
