#!/usr/bin/env bash
# Disposable account-free emulator only. Exact APK provider dispatch, not real credential success.
set -euo pipefail
APK="${1:?APK}";OUT="${2:?OUT}"
mkdir -p "$OUT/shots"
test "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" = 1
adb install -r "$APK" | tee "$OUT/google-install.txt"
adb shell am force-stop app.otpanda
adb logcat -c
adb shell monkey -p app.otpanda -c android.intent.category.LAUNCHER 1 > "$OUT/launch.txt" 2>&1
for attempt in $(seq 1 20); do
 sleep 2
 adb shell uiautomator dump /sdcard/google-provider-ui.xml > "$OUT/dump.txt" 2>&1
 adb pull /sdcard/google-provider-ui.xml "$OUT/pre-tap.xml"
 if python3 - "$OUT/pre-tap.xml" <<'PY'
import sys,re,subprocess,xml.etree.ElementTree as ET
for n in ET.parse(sys.argv[1]).iter('node'):
 if 'Continue with Google' in n.get('text','')+' '+n.get('content-desc',''):
  x1,y1,x2,y2=map(int,re.findall(r'\d+',n.get('bounds','')))
  subprocess.run(['adb','shell','input','tap',str((x1+x2)//2),str((y1+y2)//2)],check=True)
  sys.exit(0)
sys.exit(1)
PY
 then break;fi
done
sleep 10
adb exec-out screencap -p > "$OUT/shots/google-provider-dispatch.png"
adb shell dumpsys activity activities > "$OUT/activities.txt"
adb logcat -d -v threadtime > "$OUT/provider-logcat.txt"
adb shell uiautomator dump /sdcard/google-provider-ui.xml > "$OUT/dump-after.txt" 2>&1
adb pull /sdcard/google-provider-ui.xml "$OUT/post-tap.xml"
if grep -Ei 'CredentialManager|CredentialProvider|GetCredential|GoogleId|credentials.*getCredential' "$OUT/provider-logcat.txt" > "$OUT/provider-evidence.txt"; then
 echo 'PROVIDER_DISPATCH_OBSERVED, inspect exact logcat and pixels, no real credential success claimed' | tee "$OUT/result.txt"
else echo 'PROVIDER_DISPATCH_UNVERIFIED' | tee "$OUT/result.txt";exit 1;fi
if grep -E 'topResumedActivity|mResumedActivity' "$OUT/activities.txt" | grep -iE 'chrome|browser';then echo 'UNEXPECTED_BROWSER_DISPATCH';exit 1;fi
