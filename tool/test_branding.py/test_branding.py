#!/usr/bin/env python3
"""Run after bootstrap; verify generated metadata without image dependencies."""
from pathlib import Path
import json,struct,xml.etree.ElementTree as ET
html=Path('web/index.html').read_text();m=json.loads(Path('web/manifest.json').read_text())
assert '<title>OTPanda</title>' in html and 'A new Flutter project' not in html
assert m['name']==m['short_name']=='OTPanda'
assert m['scope']==m['id']==m['start_url']=='/app/'
assert 'not connected' in m['description'] and 'portrait-primary' not in m
for icon in m['icons']:
 b=Path('web',icon['src']).read_bytes();w,h=struct.unpack('>II',b[16:24]);assert icon['sizes']==f'{w}x{h}'
assert struct.unpack('>II',Path('web/social-preview-v7.png').read_bytes()[16:24])==(1200,630)
root=ET.parse('android/app/src/main/AndroidManifest.xml').getroot();app=root.find('application');ns='{http://schemas.android.com/apk/res/android}'
assert app.attrib[ns+'label']=='OTPanda'
assert app.attrib[ns+'description']=='@string/app_description'
ET.parse('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml')
for size in (16,32,64,128,256,512,1024):
 b=Path(f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png').read_bytes();assert struct.unpack('>II',b[16:24])==(size,size)
print('Branding metadata and generated image dimensions verified')

assert 'otty-favicon-v7-16.png' in html and 'otty-favicon-v7-32.png' in html
for size in (16,32):
 b=Path(f'web/otty-favicon-v7-{size}.png').read_bytes();assert struct.unpack('>II',b[16:24])==(size,size)
 # Preserve supplied PNG encoding byte-for-byte (indexed, RGB or RGBA).
 assert b[25] in (2,3,6)

for name in ('otty-favicon-v7-16.png','otty-favicon-v7-32.png'):
 assert Path('web',name).read_bytes()==Path('assets/brand-v7',name.replace('otty-favicon-v7-','otty-tile-')).read_bytes()
