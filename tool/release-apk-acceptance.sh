#!/usr/bin/env bash
set -euo pipefail
adb root
adb wait-for-device
mkdir -p repair-out
printf '%s\n' '8f150b01fcf3e17acb98584fbe36df1eafa85c1d1cdb375b551e3a602006d228  original-alpha6/otpanda-android-google-native-candidate.apk' 'cacc2ec1339e9727f11fa7d2c2bce3134de8c0cda33a4208e11d46a6a61939c4  original-alpha6/otpanda-android-fdroid-native-candidate.apk' '2b13c054117ecbe54d87e08d759ebb8f01534c3a8ecde50444034e5bc8aad771  broken-alpha7.apk' 'cc2733a90897c92a8f58fa6bdaee4a2a9831e3e4a7517f5e9c7e876ed52100ea  previous-alpha12/google.apk' 'f5908a40b357334e5b3c7f0f0680e09298e9a692d5cc1e558be1ff17ab5042ac  previous-alpha12/fdroid.apk' 'f436cc8fe764ff48ec649c93432410f80974b07afe87f3146fbd823e01e22ddf  previous-alpha13/google.apk' '0f8c3c83e9cfce923083898c85874ee2f2223cb6213f113cd9bad2a30b1246e3  previous-alpha13/fdroid.apk' '99672f27dc93767adc28310bef08c3af824d5fa53fbc6d467486b53b2ac97d88  previous-alpha14/google.apk' 'e4eca550f6c25a5f305438bba15c6fbb17678e8f635be548d4034c88e1950562  previous-alpha14/fdroid.apk' 'b55a880d64107a6af329850a9fac4df04ef2a7d14fd92d0ce7b5d65da72193d4  previous-alpha15/google.apk' '06da86fb167ded575a579293ab2b4e967fde9170275a91918be5197a489dda2f  previous-alpha15/fdroid.apk' | sha256sum -c - | tee repair-out/pinned-fixtures.txt
sign_in(){
 local name="$1"
 adb shell am force-stop app.otpanda
 adb shell am start -n app.otpanda/.MainActivity
 local ready=false
 local start=$SECONDS
 for i in $(seq 1 25);do
  sleep 2
  rm -f repair-out/current.xml
  adb shell rm -f /sdcard/release.xml
  if adb shell uiautomator dump /sdcard/release.xml && adb pull /sdcard/release.xml repair-out/current.xml;then
   if grep -q 'Sign-in on this device is not ready' repair-out/current.xml;then break;fi
   if grep -q 'Sign in with a passkey' repair-out/current.xml && grep -q 'Create account with a passkey' repair-out/current.xml;then ready=true;break;fi
  fi
 done
 # A semantics tree can be ready before the compositor displays a frame.
 # Keep the first frame and every retry; fail after 20 seconds, never hide it.
 local frame_start=$SECONDS frame_ok=false
 for attempt in $(seq 0 10);do
  adb exec-out screencap -p > "repair-out/$name-frame-$attempt.png"
  if java tool/CheckStartupFrame.java "repair-out/$name-frame-$attempt.png";then
   cp "repair-out/$name-frame-$attempt.png" "repair-out/$name-signin.png"
   frame_ok=true
   printf 'first usable captured frame: %ss since launch; %ss after semantics; attempt %s\n' "$((SECONDS-start))" "$((SECONDS-frame_start))" "$attempt" > "repair-out/$name-frame-timing.txt"
   break
  fi
  test "$((SECONDS-frame_start))" -lt 20 || break
  sleep 1
 done
 test "$frame_ok" = true || { echo "No meaningful app frame within bounded capture window"; return 1; }
 adb shell uiautomator dump /sdcard/release.xml
 adb pull /sdcard/release.xml repair-out/current.xml
 test -f repair-out/current.xml && cp repair-out/current.xml "repair-out/$name-signin.xml"
 if grep -Eq 'Sign-in on this device is not ready|Open OTPanda in your browser|This development build cannot sign in' repair-out/current.xml;then return 1;fi
 test "$ready" = true
 grep -q 'Sign in with a passkey' repair-out/current.xml
 grep -q 'Create account with a passkey' repair-out/current.xml
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
 for source in "original-alpha6/otpanda-android-$flavor-native-candidate.apk" broken-alpha7.apk "previous-alpha12/$flavor.apk" "previous-alpha13/$flavor.apk" "previous-alpha14/$flavor.apk" "previous-alpha15/$flavor.apk";do
  name="$flavor-$(dirname "$source" | tr / _)-$(basename "$source" .apk)"
  adb uninstall app.otpanda || true
  adb install "$source" 2>&1 | tee "repair-out/$name-initial.txt"
  grep -q '^Success' "repair-out/$name-initial.txt"
  adb shell dumpsys package app.otpanda > "repair-out/$name-before.txt"
  adb shell 'mkdir -p /data/user/0/app.otpanda/files; echo otpanda-synthetic-upgrade-sentinel > /data/user/0/app.otpanda/files/upgrade-proof'
  before=$(adb shell dumpsys package app.otpanda | grep 'firstInstallTime=' | head -1)
  adb install -r "$apk" 2>&1 | tee "repair-out/$name-upgrade.txt"
  grep -q '^Success' "repair-out/$name-upgrade.txt"
  adb shell dumpsys package app.otpanda > "repair-out/$name-after.txt"
  old_code=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' "repair-out/$name-before.txt" | head -1)
  new_code=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' "repair-out/$name-after.txt" | head -1)
  test "$new_code" -gt "$old_code"
  test "$new_code" -gt 2026112615
  grep -Eq "^[[:space:]]*versionName=${GITHUB_REF_NAME#v}$" "repair-out/$name-after.txt"
  after=$(adb shell dumpsys package app.otpanda | grep 'firstInstallTime=' | head -1)
  test "$before" = "$after"
  adb shell cat /data/user/0/app.otpanda/files/upgrade-proof | tee "repair-out/$name-preserved-data.txt"
  grep -q 'otpanda-synthetic-upgrade-sentinel' "repair-out/$name-preserved-data.txt"
  sign_in "$name"
 done
 if [ "$flavor" = google ];then
  grep -q 'Continue with Google' "repair-out/$name-signin.xml"
 fi
 sha256sum "$apk" >> repair-out/exact-installed-apk-sha256.txt
done
