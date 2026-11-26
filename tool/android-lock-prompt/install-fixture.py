#!/usr/bin/env python3
"""Idempotent. Copies the debug-only lock-prompt fixture (host Activity extending the real MainActivity, fake LockApi, synthetic credential provider) into the
generated android/app/src/debug source set and declares it in the DEBUG manifest only. Never touches main, release, MainActivity, AppLockHost or Dart.
Run from the repo root after tool/bootstrap.sh."""
import re, shutil
from pathlib import Path
here = Path(__file__).resolve().parent
dbg = Path('android/app/src/debug')
dst = dbg / 'kotlin' / 'app' / 'otpanda' / 'fixture'
dst.mkdir(parents=True, exist_ok=True)
for f in (here / 'debug').glob('*.kt'):
    shutil.copyfile(f, dst / f.name)
xml = dbg / 'res' / 'xml'
xml.mkdir(parents=True, exist_ok=True)
shutil.copyfile(here / 'debug' / 'provider.xml', xml / 'lockfx_provider.xml')
m = dbg / 'AndroidManifest.xml'
t = m.read_text()
if 'LockPromptHostActivity' not in t:
    body = '''        <activity android:name="app.otpanda.fixture.LockPromptHostActivity" android:exported="true" android:launchMode="singleTop"
            android:theme="@style/NormalTheme" android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true" android:windowSoftInputMode="adjustResize"/>
        <service android:name="app.otpanda.fixture.SyntheticProviderService" android:enabled="true" android:exported="true"
            android:label="OTPanda synthetic fixture provider" android:permission="android.permission.BIND_CREDENTIAL_PROVIDER_SERVICE">
            <intent-filter><action android:name="android.service.credentials.CredentialProviderService"/></intent-filter>
            <meta-data android:name="android.credentials.provider" android:resource="@xml/lockfx_provider"/>
        </service>
        <activity android:name="app.otpanda.fixture.SyntheticAssertionActivity" android:exported="false">
            <intent-filter><action android:name="app.otpanda.fixture.SYNTHETIC_GET_PASSKEY"/><category android:name="android.intent.category.DEFAULT"/></intent-filter>
        </activity>
'''
    if '</application>' in t:
        t = t.replace('</application>', body + '    </application>', 1)
    elif '<application' in t:
        t = re.sub(r'<application([^>]*?)\s*/>', lambda mo: '<application' + mo.group(1) + '>\n' + body + '    </application>', t, count=1)
    else:
        t = t.replace('</manifest>', '    <application>\n' + body + '    </application>\n</manifest>', 1)
    m.write_text(t)
print('installed lock-prompt fixture into', dbg)
