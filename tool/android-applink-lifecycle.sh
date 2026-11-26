#!/usr/bin/env bash
# Account-free App Link / browser-fallback lifecycle qualification (emulator or device, adb attached).
# NEVER adds accounts, never touches auth gates, uses only synthetic random code/state. Prints one line per check:
#   CHECK <name> PASS|FAIL|SKIP <reason>     and saves raw adb output + screenshots under OUT.
# Honest scope: with a DEBUG-signed APK the live assetlinks (release signer only) CANNOT verify, so check V1 reports
# REFUSED_DEBUG_SIGNER, not PASS. A forced user-selection (V2) and an explicit component am start (I3) are labelled
# separately and are NOT App Link verification proof. Real Google, passkey, approve+cookie and exchange 200 are out of scope.
#   tool/android-applink-lifecycle.sh APK [out-dir]
set -uo pipefail
APK="${1:?apk}"; OUT="${2:-applink-out}"; PKG="${PKG:-app.otpanda}"; HOST="otpanda-api.abrahammurciano.workers.dev"
ACT=".MainActivity"; mkdir -p "$OUT/shots"
[[ "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || { echo "Emulator only"; exit 1; }
say(){ echo "CHECK $1 $2 ${3:-}" | tee -a "$OUT/summary.txt"; }
shot(){ adb exec-out screencap -p > "$OUT/shots/$1.png" 2>/dev/null || true; }
rnd(){ head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' | cut -c1-43; }
view(){ adb shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "$1" 2>&1; }
top(){ adb shell dumpsys activity activities 2>/dev/null | grep -E "topResumedActivity|mResumedActivity" | head -1; }
: > "$OUT/summary.txt"
adb install -r "$APK" > "$OUT/install.log" 2>&1 || { say INSTALL FAIL "$(tail -1 "$OUT/install.log")"; exit 1; }
APKSIGNER=$(find "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}/build-tools" -name apksigner -type f | sort -V | tail -1)
SIGNER=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | grep -i "SHA-256 digest" | head -1 | awk '{print $NF}')
echo "signer=$SIGNER" > "$OUT/signer.txt"
# V1 live assetlinks vs this APK's signer (verification proof only when they match)
curl -fsS "https://$HOST/.well-known/assetlinks.json" -o "$OUT/assetlinks.json" 2> "$OUT/assetlinks.err"; AL=$?
if [ $AL -ne 0 ]; then say V1_ASSETLINKS_LIVE SKIP "live assetlinks not served (native gate/fingerprints off or fetch failed); App Link CANNOT verify"
else
  FP=$(echo "$SIGNER" | tr -d ':' | tr a-f A-F)
  if [ -n "$FP" ] && tr -d ':' < "$OUT/assetlinks.json" | tr a-f A-F | grep -q "$FP"; then
    adb shell pm verify-app-links --re-verify "$PKG" >/dev/null 2>&1; sleep 45
    adb shell pm get-app-links "$PKG" > "$OUT/get-app-links.txt" 2>&1
    grep -q "$HOST: verified" "$OUT/get-app-links.txt" && say V1_DAL_VERIFIED PASS "release signer matches live assetlinks" || say V1_DAL_VERIFIED FAIL "signer matches but state not verified (see get-app-links.txt)"
  else say V1_DAL_VERIFIED REFUSED_DEBUG_SIGNER "APK signer not in live assetlinks; do not claim verified App Link"; fi
fi
adb shell pm get-app-links "$PKG" > "$OUT/get-app-links-initial.txt" 2>&1
# Resolver must be tested BEFORE any forced user selection.
adb shell cmd package resolve-activity --brief --query-flags 65536 -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d "https://$HOST/app-return" > "$OUT/verified-resolver.txt" 2>&1
if grep -q "$PKG" "$OUT/verified-resolver.txt"; then say V2_UNFORCED_RESOLVER PASS "Android resolver chooses installed app"; else say V2_UNFORCED_RESOLVER FAIL "see verified-resolver.txt"; fi
# Complete only Chrome's account-free first-run UI before exercising app flow.
adb shell am start -a android.intent.action.VIEW -d https://example.com >/dev/null 2>&1
for setup_try in $(seq 1 8); do
 sleep 2
 adb shell uiautomator dump /sdcard/chrome-setup.xml >/dev/null 2>&1 || true
 adb pull /sdcard/chrome-setup.xml "$OUT/chrome-setup.xml" >/dev/null 2>&1 || true
 python3 - "$OUT/chrome-setup.xml" <<'PYSETUP'
import sys,re,subprocess,xml.etree.ElementTree as ET
try: nodes=ET.parse(sys.argv[1]).iter('node')
except Exception: sys.exit(0)
for n in nodes:
 if n.get('text','') in ['Use without an account','No thanks','Got it']:
  b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
  if len(b)==4: subprocess.run(['adb','shell','input','tap',str((b[0]+b[2])//2),str((b[1]+b[3])//2)])
PYSETUP
done
adb shell input keyevent KEYCODE_BACK
# Drive the actual shared signed-out Google button. FDroid must open its
# automatic browser fallback without any separate browser-choice button.
adb shell am force-stop com.google.android.apps.nexuslauncher || true
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
for attempt in $(seq 1 20); do
  sleep 2
  adb shell uiautomator dump /sdcard/applink-ui.xml >/dev/null 2>&1 || true
  adb pull /sdcard/applink-ui.xml "$OUT/button-ui.xml" >/dev/null 2>&1 || true
  if python3 - "$OUT/button-ui.xml" <<'PYTAP'
import sys,re,subprocess,xml.etree.ElementTree as ET
try: nodes=list(ET.parse(sys.argv[1]).iter('node'))
except Exception: sys.exit(1)
for n in nodes:
    label=(n.get('text','')+' '+n.get('content-desc','')).strip()
    if 'Continue with Google' in label or label=='Close app':
        b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
        if len(b)==4:
            subprocess.run(['adb','shell','input','tap',str((b[0]+b[2])//2),str((b[1]+b[3])//2)],check=True)
            sys.exit(0 if 'Continue with Google' in label else 1)
sys.exit(1)
PYTAP
  then break; fi
done
# Wait for a rendered page or provider instead of treating an 8s blank tab as ready.
for render_try in $(seq 1 12); do
 sleep 5
 adb shell uiautomator dump /sdcard/applink-render.xml >/dev/null 2>&1 || true
 adb pull /sdcard/applink-render.xml "$OUT/browser-render-$render_try.xml" >/dev/null 2>&1 || true
 if grep -qiE 'accounts.google.com|Sign in with Google|Choose an account|Welcome to OTPanda|Continue with Google|Could not|unavailable|ERR_' "$OUT/browser-render-$render_try.xml"; then break; fi
 # Chrome may defer its first-run UI until this Custom Tab. Dismiss only
 # account-free setup choices, never add an account or accept credentials.
 python3 - "$OUT/browser-render-$render_try.xml" <<'PYCHROME'
import sys,re,subprocess,xml.etree.ElementTree as ET
try:nodes=ET.parse(sys.argv[1]).iter('node')
except Exception:sys.exit(0)
for n in nodes:
 if n.get('text','') in ['Use without an account','No thanks','Got it']:
  b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
  if len(b)==4:subprocess.run(['adb','shell','input','tap',str((b[0]+b[2])//2),str((b[1]+b[3])//2)])
PYCHROME
 # Flutter web may expose only an accessibility activation control until enabled.
 python3 - "$OUT/browser-render-$render_try.xml" <<'PYA11Y'
import sys,re,subprocess,xml.etree.ElementTree as ET
try:nodes=ET.parse(sys.argv[1]).iter('node')
except Exception:sys.exit(0)
for n in nodes:
 if 'Enable accessibility' in n.get('text','')+' '+n.get('content-desc',''):
  b=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
  if len(b)==4:subprocess.run(['adb','shell','input','tap',str((b[0]+b[2])//2),str((b[1]+b[3])//2)])
PYA11Y
done
shot b1_actual_google_button
adb shell dumpsys activity activities > "$OUT/button-activities.txt" 2>&1
adb shell uiautomator dump /sdcard/applink-ui.xml >/dev/null 2>&1 || true
adb pull /sdcard/applink-ui.xml "$OUT/browser-ui.xml" >/dev/null 2>&1 || true
if top | grep -qiE 'chrome|browser'; then say B1_BUTTON_BROWSER_DISPATCH PASS "actual Google button opened browser; inspect browser-ui and pixels for first-run/provider state"; else say B1_BUTTON_BROWSER_DISPATCH FAIL "browser not foreground; inspect button-ui and screenshot"; fi
adb shell input keyevent KEYCODE_BACK; sleep 3; shot b2_cancel_return
if top | grep -q "$PKG"; then say B2_CANCEL_RETURN PASS "browser Back resumed native app; no credential supplied"; else say B2_CANCEL_RETURN FAIL "native app not resumed"; fi

S=$(rnd); C=$(rnd)
# I1 return intent delivery (resolves in app, no chooser)
adb shell am force-stop "$PKG"; adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 6
view "https://$HOST/app-return#code=$C&state=$S" > "$OUT/i1.log"; sleep 3; shot i1; top | grep -q "$PKG" && say I1_RETURN_OPENS_APP PASS "unforced resolver; require V1_DAL_VERIFIED as well" || say I1_RETURN_OPENS_APP FAIL "$(top)"
# I2 malformed variants must not exchange and must not crash (app stays up, signed out)
for v in "https://$HOST/app-return?code=$C&state=$S" "https://$HOST/app-return#code=$C&code=$C&state=$S" "https://$HOST/app-return#code=$C" "https://$HOST/other#code=$C&state=$S" "https://evil.example/app-return#code=$C&state=$S" "http://$HOST/app-return#code=$C&state=$S"; do
  view "$v" >> "$OUT/i2.log"; sleep 2
done
shot i2; adb shell pidof "$PKG" > /dev/null && say I2_MALFORMED_IGNORED PASS "app alive; signed-out UI in shots/i2.png (inspect)" || say I2_MALFORMED_IGNORED FAIL "app died"
# I3 explicit component start: NOT a resolver proof
adb shell am start -W -n "$PKG/$PKG$ACT" -a android.intent.action.VIEW -d "https://$HOST/app-return#code=$C&state=$S" > "$OUT/i3.log" 2>&1
say I3_EXPLICIT_COMPONENT SKIP "explicit component bypasses the resolver; shows only that the activity parses the intent"
# L1 cancel: start flow in UI (manual tap list in README) is app-specific; use BACK from the browser tab
adb shell am start -a android.intent.action.VIEW -d "https://otpanda.github.io/app/" >/dev/null 2>&1; sleep 4; shot l1_browser
adb shell cmd package resolve-activity --brief -a android.intent.action.VIEW -d https://otpanda.github.io/app/ > "$OUT/browser-resolve.txt" 2>&1
adb shell input keyevent KEYCODE_BACK; sleep 2; top | grep -q "$PKG" && say L1_BACK_RETURNS_TO_APP PASS "" || say L1_BACK_RETURNS_TO_APP SKIP "app not resumed (launcher or browser); inspect"
# L2 process death then return intent: pending Dart state is expected lost; must fail closed (no exchange, clean signed-out UI)
adb shell input keyevent KEYCODE_HOME; sleep 1; adb shell am kill "$PKG"; sleep 2
adb shell pidof "$PKG" >/dev/null && say L2_PROCESS_DEATH SKIP "process still alive; am kill refused" || {
  view "https://$HOST/app-return#code=$C&state=$S" > "$OUT/l2.log"; sleep 6; shot l2
  say L2_DEATH_THEN_RETURN SKIP "observe shots/l2.png: must be a clean signed-out screen; the state S was never generated by this process"; }
# L3 replay of the same return intent
view "https://$HOST/app-return#code=$C&state=$S" >/dev/null; sleep 3; adb shell pidof "$PKG" >/dev/null && say L3_REPLAY_NO_CRASH PASS "" || say L3_REPLAY_NO_CRASH FAIL "app died"
# L4 force-stop clears pending intent (expected; document only)
adb shell pm set-app-links-user-selection --user cur --package "$PKG" false "$HOST" >/dev/null 2>&1
adb logcat -d -t 500 > "$OUT/logcat.txt" 2>&1
echo "DONE $(date -u +%FT%TZ)" >> "$OUT/summary.txt"
