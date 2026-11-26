#!/usr/bin/env bash
set -euo pipefail
mkdir -p back-out
adb install -r build/app/outputs/flutter-apk/app-fdroid-debug.apk
adb shell monkey -p app.otpanda -c android.intent.category.LAUNCHER 1
for wait_try in $(seq 1 30);do
 sleep 2
 adb shell uiautomator dump /sdcard/ready.xml || true
 adb pull /sdcard/ready.xml back-out/ready.xml || true
 if grep -q Settings back-out/ready.xml;then break;fi
done
adb logcat -d > back-out/startup-logcat.txt
shot(){ adb exec-out screencap -p > "back-out/$1.png";adb shell uiautomator dump /sdcard/back.xml;adb pull /sdcard/back.xml "back-out/$1.xml"; }
shot codes
# Click actual shared Settings control by accessibility label and record layout.
python3 tool/native-back-fixture/tap.py 'Settings'
sleep 3
shot settings
python3 tool/native-back-fixture/tap.py 'About'
sleep 3
shot about
adb shell input keyevent KEYCODE_BACK
sleep 2
shot back-settings
adb shell dumpsys activity activities > back-out/activity-settings.txt
grep -q app.otpanda back-out/activity-settings.txt
adb shell input keyevent KEYCODE_BACK
sleep 2
shot back-codes
adb shell dumpsys activity activities > back-out/activity-codes.txt
grep -q app.otpanda back-out/activity-codes.txt
