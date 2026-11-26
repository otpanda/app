#!/usr/bin/env bash
# Runtime qualification of the real Credential Manager prompt against the repo's real MainActivity lifecycle (UNRUN until a booted API 34 emulator executes it).
# Debug-only. A debug Activity EXTENDS the real MainActivity; the real LocalLockRecoveryHost runs with a FAKE LockApi (fake begin/finish, real wire shapes) and a
# SYNTHETIC debug credential provider that answers with a throwaway-key assertion. No network, server, real key or account. Evidence under OUT:
#   fixture.log, shots/*.png, ui-*.xml (uiautomator dumps), window-*.txt (focus), credential_service.txt, logcat-*.txt, build.log
# Usage (repo root, after tool/bootstrap.sh, one booted emulator): tool/android-lock-prompt-qualification.sh OUT
# Env: LOCKFX_MODE (both|loopback|dart, default both), EXPECT_API (34), DEVICE, PKG (app.otpanda), APK (skip the build), REQUIRE_NO_SELF_STOP=1 (CI), RELEASE_APK (also run the release-artifact negative check).
# loopback = native host over an in-process loopback. dart = the REAL Dart LocalLockController over the real engine channels (lock_fixture_main.dart; mode extra).
# Pass/fail comes ONLY from tool/android-lock-prompt/verify-log.py. Build/install/enable/launch failures are HARNESS failures, never evidence or a pass.
set -uo pipefail
OUT="${1:?usage: $0 OUT}"; mkdir -p "$OUT/shots"
root=$(cd "$(dirname "$0")/.." && pwd); fx="$root/tool/android-lock-prompt"
EXPECT_API="${EXPECT_API:-34}"; PKG="${PKG:-app.otpanda}"; MODE="${LOCKFX_MODE:-both}"
case "$MODE" in both) MODES=loopback,dart;; loopback|dart) MODES=$MODE;; *) echo "HARNESS FAIL: LOCKFX_MODE must be both|loopback|dart"; exit 2;; esac
A=(adb); [ -n "${DEVICE:-}" ] && A=(adb -s "$DEVICE")
[ "$("${A[@]}" shell getprop ro.kernel.qemu | tr -d '\r\n')" = 1 ] || { echo 'HARNESS FAIL: refusing non-emulator'; exit 2; }
api=$("${A[@]}" shell getprop ro.build.version.sdk | tr -d '\r\n')
[ "$api" = "$EXPECT_API" ] || { echo "HARNESS FAIL: emulator API $api != $EXPECT_API"; exit 3; }
cd "$root"
python3 "$fx/check.py" || { echo 'HARNESS FAIL: source guard'; exit 4; }
python3 "$fx/install-fixture.py" || exit 4
if [ -z "${APK:-}" ]; then
  flutter build apk --debug --flavor google -t tool/android-lock-prompt/lock_fixture_main.dart > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo 'HARNESS FAIL: build'; exit 5; }
  APK=build/app/outputs/flutter-apk/app-google-debug.apk
fi
python3 "$fx/check-release-artifact.py" --expect-present "$APK" > "$OUT/debug-apk-contains-fixture.txt" 2>&1 || { cat "$OUT/debug-apk-contains-fixture.txt"; echo 'HARNESS FAIL: debug APK lacks the fixture classes'; exit 5; }
[ -z "${RELEASE_APK:-}" ] || python3 "$fx/check-release-artifact.py" "$RELEASE_APK" || { echo 'FAIL: release APK contains fixture classes'; exit 5; }
"${A[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
"${A[@]}" install -t -r "$APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; echo 'HARNESS FAIL: install'; exit 6; }
"${A[@]}" shell input keyevent KEYCODE_WAKEUP; "${A[@]}" shell wm dismiss-keyguard; sleep 1
comp="$PKG/app.otpanda.fixture.SyntheticProviderService"
cur=$("${A[@]}" shell settings get secure credential_service | tr -d '\r\n')
case "$cur" in null|"") new="$comp";; *"$comp"*) new="$cur";; *) new="$cur:$comp";; esac
"${A[@]}" shell settings put secure credential_service "$new"
back=$("${A[@]}" shell settings get secure credential_service | tr -d '\r\n')
{ echo "before=$cur"; echo "after=$back"; echo "primary=$("${A[@]}" shell settings get secure credential_service_primary | tr -d '\r\n')"; } > "$OUT/credential_service.txt"
case "$back" in *"$comp"*) ;; *) echo 'HARNESS FAIL: provider enablement readback does not contain the synthetic provider'; cat "$OUT/credential_service.txt"; exit 7;; esac
# Fresh emulator launcher can ANR while Play services finishes first startup.
# Clear the disposable launcher's startup task before any evidence scenario.
"${A[@]}" shell am force-stop com.google.android.apps.nexuslauncher
"${A[@]}" shell input keyevent KEYCODE_HOME; sleep 5
"${A[@]}" logcat -b crash -c; : > "$OUT/fixture.log"; echo "API=$api" >> "$OUT/fixture.log"; echo 'ENABLE=OK' >> "$OUT/fixture.log"; echo "MODES=$MODES" >> "$OUT/fixture.log"
hostact="$PKG/app.otpanda.fixture.LockPromptHostActivity"
mark(){ "${A[@]}" shell log -t LOCKFX "ev=mark scenario=$1 name=$2 $3"; }
dump_ui(){ # scenario label -> OUT/ui-s-l.xml
  "${A[@]}" shell uiautomator dump /sdcard/lockfx-ui.xml >/dev/null 2>&1; "${A[@]}" pull /sdcard/lockfx-ui.xml "$OUT/ui-$1-$2.xml" >/dev/null 2>&1 || : > "$OUT/ui-$1-$2.xml"
}
idle(){
  local s="$1"; local f="$OUT/window-$s-idle.txt"
  "${A[@]}" shell dumpsys window displays 2>&1 | tr -d '\r' > "$f"
  local v; v=$(grep -m1 'mCurrentFocus' "$f" | sed 's/.*{[^ ]* [^ ]* //; s/}.*//' | tr -c 'A-Za-z0-9._/\n' '_')
  [ -n "$v" ] && mark "$s" FOCUS_IDLE "value=$v" || mark "$s" FOCUS_ERROR ""
  dump_ui "$s" idle
  python3 "$fx/tap-entry.py" "$OUT/ui-$s-idle.xml" 'Synthetic fixture passkey' 'synthetic-fixture-user' >/dev/null && mark "$s" ENTRY_VISIBLE value=yes || mark "$s" ENTRY_VISIBLE value=no
  local p="$OUT/shots/$s-idle.png"; "${A[@]}" exec-out screencap -p > "$p"
  [ "$(head -c4 "$p" | tail -c3)" = PNG ] && [ "$(stat -c%s "$p")" -gt 2000 ] && mark "$s" SHOT_OK "file=$s-idle.png"
}
select_entry(){
  local s="$1" xy
  xy=$(python3 "$fx/tap-entry.py" "$OUT/ui-$s-idle.xml" 'Synthetic fixture passkey' 'synthetic-fixture-user') || return 0
  mark "$s" TAP_ENTRY ""; "${A[@]}" shell input tap $xy; sleep 3
  # At most ONE confirm tap, and only on an exact clickable node (Sign in / Continue); logged with the node label.
  dump_ui "$s" after1
  if xy=$(python3 "$fx/tap-entry.py" --exact-clickable "$OUT/ui-$s-after1.xml" 'Continue' 'Sign in'); then
    mark "$s" TAP_CONFIRM "xy=${xy// /,}"; "${A[@]}" shell input tap $xy; sleep 3
  fi
  local p="$OUT/shots/$s-after.png"; "${A[@]}" exec-out screencap -p > "$p"
}
run(){ # scenario action steps... (env RUN_MODE=loopback|dart, RUN_CANCEL_MS)
  local s="$1" act="$2"; shift 2
  # A selector is a separate system task, not killed by force-stopping our app.
  # End it between scenarios so each run must log a fresh real host creation.
  "${A[@]}" shell am force-stop com.android.credentialmanager
  "${A[@]}" shell am force-stop "$PKG"; "${A[@]}" shell run-as "$PKG" rm -f no_backup/local-app-lock-v1; "${A[@]}" logcat -b all -c; sleep 1
  mark "$s" BEGIN ""
  "${A[@]}" shell am start -W -f 0x10008000 -n "$hostact" --es scenario "$s" --es action "$act" --es mode "${RUN_MODE:-loopback}" --ei cancel_ms "${RUN_CANCEL_MS:-0}" > "$OUT/start-$s.txt" 2>&1
  if ! grep -q 'Status: ok' "$OUT/start-$s.txt" || grep -qi 'Exception\|Error:' "$OUT/start-$s.txt"; then
    cat "$OUT/start-$s.txt"; echo 'HARNESS FAIL: scenario launch did not succeed'; exit 8
  fi
  for step in "$@"; do
    case "$step" in
      wait*) sleep "${step#wait}";;
      idle) idle "$s";;
      home) mark "$s" HOME ""; "${A[@]}" shell input keyevent KEYCODE_HOME;;
      return) mark "$s" RETURN ""; "${A[@]}" shell am start -W -f 0x20000000 -n "$hostact" >> "$OUT/start-$s.txt" 2>&1
        sleep 2; "${A[@]}" shell dumpsys window displays 2>&1 | tr -d '\r' > "$OUT/window-$s-return.txt"
        rf=$(grep -m1 mCurrentFocus "$OUT/window-$s-return.txt" | sed 's/.*{[^ ]* [^ ]* //; s/}.*//' | tr -c 'A-Za-z0-9._/\n' '_'); mark "$s" RETURN_FOCUS "value=$rf"
        # HOME does not dismiss the selector task. If it still covers the app, press BACK once so the app can resume (logged; the selector state is a reported fact).
        case "$rf" in com.android.credentialmanager*|com.google.android.gms*) mark "$s" BACK_AFTER_RETURN ""; "${A[@]}" shell input keyevent KEYCODE_BACK;; esac
        for _ in $(seq 1 20); do "${A[@]}" logcat -d -b all 2>/dev/null | grep LOCKFX | awk -v scenario="scenario=$s" 'index($0,scenario) && /name=RETURN / {seen=1;next} seen && index($0,scenario)' | grep -q 'ev=dart_lifecycle.*state=resumed' && break; sleep 1; done
        "${A[@]}" shell dumpsys window displays 2>&1 | tr -d '\r' > "$OUT/window-$s-resumed.txt"
        mark "$s" FOCUS_AFTER_RESUME "value=$(grep -m1 mCurrentFocus "$OUT/window-$s-resumed.txt" | sed 's/.*{[^ ]* [^ ]* //; s/}.*//' | tr -c 'A-Za-z0-9._/\n' '_')"
        sleep 3;;
      focusafter)
        # Observe completion before sampling focus, not merely an elapsed timer.
        local complete=false
        for attempt in $(seq 1 25); do
          "${A[@]}" logcat -d -b all -v threadtime > "$OUT/cancel-wait-$s.txt"
          if grep -q 'ev=dart_channel_cancel' "$OUT/cancel-wait-$s.txt" && grep -q 'ev=dart_outcome' "$OUT/cancel-wait-$s.txt"; then complete=true; break; fi
          sleep 1
        done
        [ "$complete" = true ] || { echo 'HARNESS FAIL: Dart cancel/outcome never completed'; exit 9; }
        "${A[@]}" shell dumpsys window displays 2>&1 | tr -d '\r' > "$OUT/window-$s-after-cancel.txt"
        mark "$s" FOCUS_AFTER_CANCEL "value=$(grep -m1 mCurrentFocus "$OUT/window-$s-after-cancel.txt" | sed 's/.*{[^ ]* [^ ]* //; s/}.*//' | tr -c 'A-Za-z0-9._/\n' '_')";;
      back) mark "$s" BACK ""; "${A[@]}" shell input keyevent KEYCODE_BACK;;
      select) select_entry "$s";;
    esac
  done
  echo "== scenario $s" >> "$OUT/fixture.log"
  "${A[@]}" logcat -d -b all -v threadtime | tr -d '\r' > "$OUT/logcat-$s.txt"
  grep 'LOCKFX' "$OUT/logcat-$s.txt" | grep 'ev=' >> "$OUT/fixture.log"
  # A capability warning can concern a different installed provider. Attribute
  # rejection only if our provider was never invoked. Functional gates still
  # require its visible entry, selection and matching finish independently.
  if grep -q 'does not have the required capabilities' "$OUT/logcat-$s.txt" && ! grep -q 'ev=provider_begin_get' "$OUT/logcat-$s.txt"; then
    echo "PROVIDER_REJECTED=yes scenario=$s" >> "$OUT/fixture.log"
  fi
}
case "$MODES" in *loopback*)
run unlock_idle unlock wait12 idle wait3
run unlock_back unlock wait12 idle back wait3
run unlock_home unlock wait12 idle home wait4
run unlock_select unlock wait12 idle select wait4
run disable_select disable wait12 idle select wait4;; esac
case "$MODES" in *dart*)
export RUN_MODE=dart
run dart_unlock_idle unlock wait12 idle wait3
run dart_back unlock wait12 idle back wait3
RUN_CANCEL_MS=30000 run dart_cancel unlock wait12 idle focusafter wait4
run dart_home unlock wait12 idle home wait4 return wait3
run dart_unlock_select unlock wait12 idle select wait8
run dart_disable_select disable wait12 idle select wait8;; esac
"${A[@]}" logcat -d -b crash 2>&1 | tr -d '\r' > "$OUT/logcat-crash.txt"
grep -qi 'FATAL\|ANR\|not responding' "$OUT/logcat-crash.txt" && echo 'CRASH=yes' >> "$OUT/fixture.log"
if [ "$cur" = null ] || [ -z "$cur" ]; then "${A[@]}" shell settings delete secure credential_service >/dev/null 2>&1; else "${A[@]}" shell settings put secure credential_service "$cur" >/dev/null 2>&1; fi
"${A[@]}" shell am force-stop "$PKG"; "${A[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
python3 "$fx/verify-log.py" "$OUT/fixture.log" "$EXPECT_API"
