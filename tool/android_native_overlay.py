#!/usr/bin/env python3
"""Idempotent Android native overlay, run by tool/bootstrap.sh after the host is
generated and renamed to app.otpanda. Copies the tracked Kotlin sources, adds the
credentials dependencies and the HTTPS App Link return filter. No signer, key or
account material lives here."""
import shutil
from pathlib import Path
root = Path('android/app/src')
here = Path(__file__).parent / 'android-native'
for flavor in ('main', 'google', 'fdroid'):
    dst = root / flavor / 'kotlin' / 'app' / 'otpanda'
    dst.mkdir(parents=True, exist_ok=True)
    for f in (here / flavor).glob('*.kt'):
        shutil.copyfile(f, dst / f.name)
# The OS-gated enrolled-device key (inactive; nothing in Dart calls it yet).
rec = root / 'main' / 'kotlin' / 'org' / 'otpanda' / 'recovery'
rec.mkdir(parents=True, exist_ok=True)
for f in (Path(__file__).parent / 'android-recovery').glob('*.kt'):
    if not f.name.endswith('Test.kt'):
        shutil.copyfile(f, rec / f.name)
g = Path('android/app/build.gradle.kts'); s = g.read_text()
if 'androidx.credentials:credentials:' not in s:
    s = s.rstrip('\n') + '''

dependencies {
    // Core Credential Manager (passkeys) has no Google Play Services dependency,
    // so both flavors carry it. The Play Services bridge and Google ID are google-only.
    implementation("androidx.credentials:credentials:1.3.0")
    "googleImplementation"("androidx.credentials:credentials-play-services-auth:1.3.0")
    "googleImplementation"("com.google.android.libraries.identity.googleid:googleid:1.1.1")
}
'''
    g.write_text(s)
m = Path('android/app/src/main/AndroidManifest.xml'); t = m.read_text()
if 'android:path="/app-return"' not in t:
    flt = '''            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https" android:host="otpanda-api.abrahammurciano.workers.dev" android:path="/app-return"/>
            </intent-filter>
'''
    t = t.replace('        </activity>', flt + '        </activity>', 1)
    m.write_text(t)
if 'android.permission.USE_BIOMETRIC' not in t:
    t = t.replace('<application', '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>\n    <application', 1)
    m.write_text(t)
