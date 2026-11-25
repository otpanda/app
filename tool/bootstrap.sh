#!/usr/bin/env bash
set -euo pipefail
# Generated platform hosts are temporary until stable package/signing identity is
# selected. Reproducible source lives in lib/, test/ and the pinned pubspec lock.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
flutter create --platforms=android,web,linux,windows,macos --org org.otpanda.development --project-name otpanda_client "$tmp/host"
for platform in android web linux windows macos; do
  if [ ! -d "$platform" ]; then cp -R "$tmp/host/$platform" "$platform"; fi
done
# Never mislabel a debug-key signature as a trusted release.
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/build.gradle.kts')
s=p.read_text().replace('            signingConfig = signingConfigs.getByName("debug")\n','')
p.write_text(s)
PY
# Manifest: camera (optional feature so devices without one can still use
# manual entry), INTERNET (the debug/profile manifests add it, main does not),
# and removal of audio/storage permissions the camera plugin would merge.
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/src/main/AndroidManifest.xml')
s=p.read_text()
if 'xmlns:tools' not in s:
    s=s.replace('<manifest ','<manifest xmlns:tools="http://schemas.android.com/tools" ',1)
add=''
if 'android.permission.CAMERA' not in s:
    add+='    <uses-permission android:name="android.permission.CAMERA"/>\n    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n'
if 'android.permission.INTERNET' not in s:
    add+='    <uses-permission android:name="android.permission.INTERNET"/>\n'
if 'RECORD_AUDIO' not in s:
    for n in ['RECORD_AUDIO','WRITE_EXTERNAL_STORAGE','READ_EXTERNAL_STORAGE']:
        add+='    <uses-permission android:name="android.permission.%s" tools:node="remove"/>\n'%n
if add:
    s=s.replace('<application',add+'    <application',1)
p.write_text(s)
PY
node --test test/session_bootstrap_test.cjs
node tool/build-assignment-host.mjs web/assignment-host.js
python3 tool/brand_hosts.py
python3 tool/test_branding.py/test_branding.py
python3 tool/decode_fonts.py
python3 tool/decode_zxing.py
flutter pub get
