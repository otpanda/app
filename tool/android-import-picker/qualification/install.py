#!/usr/bin/env python3
"""Install the picker fixture only into the generated DEBUG source set, never main or release."""
from pathlib import Path
import re, shutil
here = Path(__file__).resolve().parent
out = Path('android/app/src/debug/kotlin/app/otpanda/pickerfx')
out.mkdir(parents=True, exist_ok=True)
for f in (here / 'debug').glob('*.kt'):
    shutil.copyfile(f, out / f.name)
p = Path('android/app/src/debug/AndroidManifest.xml')
s = p.read_text()
body = (
    '<activity android:name="app.otpanda.pickerfx.JournalFixtureActivity" android:exported="true" android:theme="@style/NormalTheme"/>' 
    '<activity android:name="app.otpanda.pickerfx.PickerFixtureActivity" android:exported="true" '
    'android:theme="@style/NormalTheme" android:hardwareAccelerated="true"/>'
    '<provider android:name="app.otpanda.pickerfx.SyntheticDocumentsProvider" '
    'android:authorities="app.otpanda.importfixture.documents" android:exported="true" '
    'android:grantUriPermissions="true" android:permission="android.permission.MANAGE_DOCUMENTS">'
    '<intent-filter><action android:name="android.content.action.DOCUMENTS_PROVIDER"/></intent-filter></provider>'
)
if 'pickerfx.PickerFixtureActivity' not in s:
    if '</application>' in s:
        s = s.replace('</application>', body + '</application>', 1)
    elif re.search(r'<application[^>]*/>', s):
        s = re.sub(r'<application([^>]*?)/>', r'<application\1>' + body + '</application>', s, count=1)
    else:
        s = s.replace('</manifest>', '<application>' + body + '</application></manifest>', 1)
    p.write_text(s)
print('Debug-only picker fixture installed')

g=Path('android/app/build.gradle.kts');s=g.read_text();assert 'applicationId = "app.otpanda"' in s;s=s.replace('applicationId = "app.otpanda"','applicationId = "app.otpanda.importfixture"');g.write_text(s)
p=Path('android/app/src/main/AndroidManifest.xml');s=p.read_text();s=re.sub(r'<intent-filter android:autoVerify="true">.*?</intent-filter>','',s,flags=re.S);p.write_text(s)
