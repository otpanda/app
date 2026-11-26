#!/usr/bin/env bash
# Runtime qualification of the real Credential Manager prompt against the composed lifecycle (UNRUN until a booted API 34 emulator executes it).
# Debug-only synthetic fixture: fake begin transport, no network, no server, no real key, no account. Evidence lands under OUT:
#   fixture.log (marks + LOCKFX events per scenario), shots/*.png (UI), window-*.txt (focus dumps), logcat-crash.txt, build.log
# Usage (repo root, after tool/bootstrap.sh, one booted emulator): tool/android-lock-prompt-qualification.sh OUT
# Env: EXPECT_API (34), DEVICE (adb serial), PKG (app.otpanda), APK (skip the build), REQUIRE_NO_SELF_STOP=1 (gate on the prompt-caused stop).
# Pass/fail comes ONLY from tool/android-lock-prompt/verify-log.py. A build/install/launch failure is a HARNESS failure, not evidence.
set -uo pipefail
OUT="${1:?usage: $0 OUT}"; mkdir -p "$OUT/shots"
root=$(cd "$(dirname "$0")/.." && pwd); fx="$root/tool/android-lock-prompt"
EXPECT_API="${EXPECT_API:-34}"; PKG="${PKG:-app.otpanda}"
A=(adb); [ -n "${DEVICE:-}" ] && A=(adb -s "$DEVICE")
[ "$("${A[@]}" shell getprop ro.kernel.qemu | tr -d '\r\n')" = 1 ] || { echo 'HARNESS FAIL: refusing non-emulator'; exit 2; }
api=$("${A[@]}" shell getprop ro.build.version.sdk | tr -d '\r\n')
[ "$api" = "$EXPECT_API" ] || { echo "HARNESS FAIL: emulator API $api != $EXPECT_API"; exit 3; }
cd "$root"
python3 "$fx/install-fixture.py" || exit 4
if [ -z "${APK:-}" ]; then
  flutter build apk --debug --flavor google > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo 'HARNESS FAIL: build'; exit 5; }
  APK=build/app/outputs/flutter-apk/app-google-debug.apk
fi
"${A[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${A[@]}" install -t -r "$APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; echo 'HARNESS FAIL: install'; exit 6; }
"${A[@]}" shell input keyevent KEYCODE_WAKEUP; "${A[@]}" shell wm dismiss-keyguard; sleep 1
"${A[@]}" logcat -b crash -c; : > "$OUT/fixture.log"; echo "API=$api" >> "$OUT/fixture.log"
comp="$PKG/app.otpanda.fixture.LockPromptFixtureActivity"
mark(){ "${A[@]}" shell log -t LOCKFX "ev=mark scenario=$1 name=$2 $3"; }
focus(){ # scenario label
  local f="$OUT/window-$1-$2.txt"
  "${A[@]}" shell dumpsys window 2>&1 | tr -d '\r' > "$f"
  local v; v=$(grep -m1 'mCurrentFocus' "$f" | sed 's/.*{[^ ]* [^ ]* //; s/}.*//' | tr -c 'A-Za-z0-9._/\n' '_')
  [ -n "$v" ] && mark "$1" "FOCUS_$2" "value=$v" || mark "$1" FOCUS_ERROR ""
}
shot(){ local p="$OUT/shots/$1-$2.png"; "${A[@]}" exec-out screencap -p > "$p"; [ "$(head -c4 "$p" | tail -c3)" = PNG ] && [ "$(stat -c%s "$p")" -gt 2000 ] && mark "$1" SHOT_OK "file=$1-$2.png"; }
run(){ # scenario mimic actions...
  local s="$1" m="$2"; shift 2
  "${A[@]}" shell am force-stop "$PKG"; "${A[@]}" logcat -c; sleep 1
  mark "$s" BEGIN ""
  "${A[@]}" shell am start -W -n "$comp" --es scenario "$s" --ei mimic "$m" > "$OUT/start-$s.txt" 2>&1
  for act in "$@"; do
    case "$act" in
      wait*) sleep "${act#wait}";;
      idle) focus "$s" IDLE; shot "$s" idle;;
      home) mark "$s" HOME ""; "${A[@]}" shell input keyevent KEYCODE_HOME;;
      back) mark "$s" BACK ""; "${A[@]}" shell input keyevent KEYCODE_BACK;;
      return) mark "$s" RETURN ""; "${A[@]}" shell am start -n "$comp" --es scenario "$s" --ei mimic "$m" >/dev/null 2>&1;;
    esac
  done
  echo "== scenario $s" >> "$OUT/fixture.log"
  "${A[@]}" logcat -d -v threadtime -s LOCKFX:I | tr -d '\r' | grep 'ev=' >> "$OUT/fixture.log"
}
run observe_idle 0 wait8 idle back wait3
run observe_home 0 wait6 home wait4 return wait3 back wait2
run mimic_idle 1 wait8 idle wait2
run mimic_back 1 wait6 back wait3
run mimic_home 1 wait6 home wait4
"${A[@]}" logcat -d -b crash 2>&1 | tr -d '\r' > "$OUT/logcat-crash.txt"
grep -q 'FATAL\|ANR' "$OUT/logcat-crash.txt" && echo 'CRASH=yes' >> "$OUT/fixture.log"
"${A[@]}" shell am force-stop "$PKG"; "${A[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
python3 "$fx/verify-log.py" "$OUT/fixture.log" "$EXPECT_API"
