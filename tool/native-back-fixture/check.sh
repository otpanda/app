#!/usr/bin/env bash
set -euo pipefail
mkdir -p back-out
adb install -r build/app/outputs/flutter-apk/app-fdroid-debug.apk
adb shell am force-stop com.google.android.apps.nexuslauncher || true
adb shell am start -n app.otpanda/.MainActivity
for wait_try in $(seq 1 30);do
 sleep 2
 adb shell uiautomator dump /sdcard/ready.xml || true
 if grep -q "Pixel Launcher" back-out/ready.xml 2>/dev/null;then adb shell am force-stop com.google.android.apps.nexuslauncher;fi
 adb pull /sdcard/ready.xml back-out/ready.xml || true
 if grep -q 'Account &amp; security' back-out/ready.xml;then break;fi
done
adb logcat -d > back-out/startup-logcat.txt
shot(){ adb exec-out screencap -p > "back-out/$1.png";adb shell uiautomator dump /sdcard/back.xml;adb pull /sdcard/back.xml "back-out/$1.xml"; }
shot codes
# Click actual shared Settings control by accessibility label and record layout.
python3 tool/native-back-fixture/tap.py 'Account & security'
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
