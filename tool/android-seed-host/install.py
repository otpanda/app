#!/usr/bin/env python3
"""Install only into generated debug source set, never release/main."""
from pathlib import Path
import shutil,re
here=Path(__file__).resolve().parent
out=Path('android/app/src/debug/kotlin/app/otpanda/seedfixture')
out.mkdir(parents=True,exist_ok=True)
for f in (here/'debug').glob('*.kt'): shutil.copyfile(f,out/f.name)
p=Path('android/app/src/debug/AndroidManifest.xml'); s=p.read_text()
body='<activity android:name="app.otpanda.seedfixture.SeedHostActivity" android:exported="true" android:launchMode="singleTop" android:theme="@style/NormalTheme" android:hardwareAccelerated="true"/>'
if 'seedfixture.SeedHostActivity' not in s:
 if '</application>' in s:s=s.replace('</application>',body+'</application>',1)
 elif re.search(r'<application[^>]*/>',s):s=re.sub(r'<application([^>]*?)/>',r'<application\1>'+body+'</application>',s,count=1)
 else:s=s.replace('</manifest>','<application>'+body+'</application></manifest>',1)
 p.write_text(s)
print('Debug-only seed host fixture installed')
