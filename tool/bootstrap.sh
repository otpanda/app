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
# Android identity is app.otpanda (user choice, Nov 25). Applies to namespace,
# applicationId and the MainActivity package; flutter create used the
# development prefix. Idempotent.
python3 - <<'PY'
from pathlib import Path
old='org.otpanda.development.otpanda_client'
new='app.otpanda'
g=Path('android/app/build.gradle.kts')
t=g.read_text()
if old in t: g.write_text(t.replace(old,new))
src=Path('android/app/src/main/kotlin/'+old.replace('.','/'))
if src.is_dir():
    dst=Path('android/app/src/main/kotlin/app/otpanda')
    dst.mkdir(parents=True,exist_ok=True)
    for f in src.glob('*.kt'):
        (dst/f.name).write_text(f.read_text().replace('package '+old,'package '+new))
        f.unlink()
    import shutil
    shutil.rmtree(Path('android/app/src/main/kotlin/org/otpanda/development'))
PY
# Store flavors (google / fdroid), same applicationId.
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/build.gradle.kts');s=p.read_text()
if 'productFlavors' not in s:
    blk='''    // google: may bundle Google sign-in (Credential Manager) when it exists.
    // fdroid: no Google or Play Services dependency, browser sign-in only.
    flavorDimensions += "store"
    productFlavors {
        create("google") { dimension = "store" }
        create("fdroid") { dimension = "store" }
    }

'''
    p.write_text(s.replace('    buildTypes {',blk+'    buildTypes {',1))
PY
python3 tool/android_native_overlay.py
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
