#!/usr/bin/env bash
# Runs INSIDE the emulator (android-emulator-runner). Real emulator, real app
# process, real adb screenshot. It proves only: the debug APK installs, starts,
# does not crash, and shows the native signed-out sign-in screen. It is not
# Keystore/passkey/Google/camera proof and does not sign in.
set -euo pipefail
APK="${1:?apk path}"
OUT="${2:-smoke-out}"
PKG=app.otpanda
mkdir -p "$OUT"
adb install -r "$APK"
adb logcat -c
adb shell am force-stop com.google.android.apps.nexuslauncher || true
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
ok=0
for i in $(seq 1 30); do
  sleep 3
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  adb pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null 2>&1 || true
  # Fresh emulator images can show a launcher ANR over a healthy app.
  # Dismiss only that explicitly identified OS dialog, never an app ANR.
  if [ -s "$OUT/ui.xml" ] && grep -q "Pixel Launcher isn't responding" "$OUT/ui.xml"; then
    adb exec-out screencap -p > "$OUT/launcher-anr.png"
    python3 - "$OUT/ui.xml" <<'PYANR'
import sys,xml.etree.ElementTree as ET,re,subprocess
for n in ET.parse(sys.argv[1]).iter('node'):
    if n.get('text')=='Close app':
        a=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
        if len(a)==4:subprocess.run(['adb','shell','input','tap',str((a[0]+a[2])//2),str((a[1]+a[3])//2)],check=True)
PYANR
    continue
  fi
  if [ -s "$OUT/ui.xml" ] && grep -q "Continue with Google" "$OUT/ui.xml" && grep -q "Sign in with a passkey" "$OUT/ui.xml" && ! grep -q "Sign in with browser" "$OUT/ui.xml"; then ok=1; break; fi
done
adb exec-out screencap -p > "$OUT/screen.png"
adb logcat -d > "$OUT/logcat.txt" || true
adb shell pidof "$PKG" > "$OUT/pid.txt" || true
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then echo "crash in logcat"; grep -n -A12 "FATAL EXCEPTION" "$OUT/logcat.txt" | head -40; exit 1; fi
[ -s "$OUT/pid.txt" ] || { echo "app process not running"; exit 1; }
[ "$ok" = 1 ] || { echo "signed-out screen text not found in UI dump"; exit 1; }
echo "smoke ok"
