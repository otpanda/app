#!/usr/bin/env python3
"""Idempotent. Copies the debug-only lock-prompt fixture Activity into the generated android/app/src/debug source set and declares it in the DEBUG manifest only.
Never touches main, release, MainActivity, AppLockHost or any Dart. Run from the repo root after tool/bootstrap.sh."""
import shutil
from pathlib import Path
here = Path(__file__).resolve().parent
dbg = Path('android/app/src/debug')
dst = dbg / 'kotlin' / 'app' / 'otpanda' / 'fixture'
dst.mkdir(parents=True, exist_ok=True)
shutil.copyfile(here / 'LockPromptFixtureActivity.kt', dst / 'LockPromptFixtureActivity.kt')
m = dbg / 'AndroidManifest.xml'
t = m.read_text()
if 'LockPromptFixtureActivity' not in t:
    act = ('        <activity android:name="app.otpanda.fixture.LockPromptFixtureActivity" android:exported="true" android:launchMode="singleTop"\n'
           '            android:theme="@android:style/Theme.Material.Light.NoActionBar"/>\n')
    if '<application' in t and '</application>' in t:
        t = t.replace('</application>', act + '    </application>', 1)
    elif '<application' in t:  # self-closing
        import re
        t = re.sub(r'<application([^>]*?)\s*/>', lambda mo: '<application' + mo.group(1) + '>\n' + act + '    </application>', t, count=1)
    else:
        t = t.replace('</manifest>', '    <application>\n' + act + '    </application>\n</manifest>', 1)
    m.write_text(t)
print('installed lock-prompt fixture into', dbg)
