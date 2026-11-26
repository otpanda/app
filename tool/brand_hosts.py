#!/usr/bin/env python3
"""Apply OTPanda branding after flutter create. No third-party Python packages."""
from pathlib import Path
import base64, json, re, struct, zlib
import gzip, hashlib
_encoded = ''.join(''.join(Path(__file__).with_name(f'green-icons-{i}.b64').read_text().splitlines()) for i in range(8))
_raw = gzip.decompress(base64.b64decode(_encoded, validate=True))
assert hashlib.sha256(_raw).hexdigest() == 'd038531ed3620d859bacfcde8620119c0229fe4838852612f360ba501c91a2be', 'Icon payload hash mismatch'
_payload = json.loads(_raw)
_payload['icons'] = {int(k) if k.isdigit() else k:v for k,v in _payload['icons'].items()}
_payload['favicons'] = {int(k):v for k,v in _payload['favicons'].items()}
ICONS = _payload['icons']
SOCIAL = base64.b64encode(Path('assets/swirl-free-brand/social-card-left-tile-swirlfree.png').read_bytes()).decode()

def write(path, data):
 p=Path(path);p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
def icon(path,size): write(path,base64.b64decode(ICONS[size]))
description='OTPanda development preview. Explore a private code workspace with fictional accounts and codes. Real sign-in and sources are not connected yet.'
for stale in Path('web').glob('otty-favicon-v2-*.png'): stale.unlink()
for name in ['social-preview.png','icons/apple-touch-icon.png','icons/Icon-192.png','icons/Icon-512.png','icons/Icon-maskable-192.png','icons/Icon-maskable-512.png']:
 Path('web',name).unlink(missing_ok=True)
FAVICONS = _payload['favicons']
# Preserve existing extension icon assets; only HTML tab references change.
for size,data in FAVICONS.items(): write(f'web/otty-favicon-v3-{size}.png',base64.b64decode(data))
# Browser tab mark only, selected tight tile with exact original badge.
for name in ('otty-favicon-t1b.svg','otty-favicon-t1b-16.png','otty-favicon-t1b-32.png','favicon-otty-t1b.ico'):
    write('web/'+name,Path('assets/tab-favicon',name).read_bytes())
write('web/favicon.png',Path('assets/tab-favicon/otty-favicon-t1b-32.png').read_bytes())
icon('web/icons/apple-touch-icon-v4.png',180)
for size in (192,512):
 icon(f'web/icons/Icon-v4-{size}.png',size)
 icon(f'web/icons/Icon-maskable-v4-{size}.png',f'm{size}')
write('web/social-preview-v4.png',base64.b64decode(SOCIAL))
manifest=dict(id='/app/',name='OTPanda',short_name='OTPanda',description=description,start_url='/app/',scope='/app/',display='standalone',background_color='#f5f8f7',theme_color='#0a7955',lang='en',prefer_related_applications=False,icons=[dict(src=f'icons/Icon-{"maskable-" if mask else ""}v4-{size}.png',sizes=f'{size}x{size}',type='image/png',purpose='maskable' if mask else 'any') for mask in (False,True) for size in (192,512)])
Path('web/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
Path('web/session-bootstrap.js').write_text(Path('tool/session-bootstrap.js').read_text())
Path('web/realtime-client.js').write_text(Path('tool/realtime-client.js').read_text())
Path('web/recovery-bridge.js').write_text(Path('tool/recovery-bridge.js').read_text())
Path('web/native-launch-intent.js').write_text(Path('tool/native-launch-intent.js').read_text())
Path('web/extension-launch-intent.js').write_text(Path('tool/extension-launch-intent.js').read_text())
Path('web/index.html').write_text(f'''<!DOCTYPE html>
<html lang="en"><head>
<base href="$FLUTTER_BASE_HREF">
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OTPanda</title>
<meta name="application-name" content="OTPanda">
<meta name="description" content="{description}">
<meta name="theme-color" content="#0a7955">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="OTPanda">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<link rel="canonical" href="https://otpanda.github.io/app/">
<link rel="icon" type="image/png" sizes="16x16" href="otty-favicon-t1b-16.png">
<link rel="icon" type="image/png" sizes="32x32" href="otty-favicon-t1b-32.png">
<link rel="apple-touch-icon" sizes="180x180" href="icons/apple-touch-icon-v4.png">
<link rel="manifest" href="manifest.json">
<meta property="og:type" content="website">
<meta property="og:site_name" content="OTPanda">
<meta property="og:title" content="OTPanda">
<meta property="og:description" content="{description}">
<meta property="og:url" content="https://otpanda.github.io/app/">
<meta property="og:image" content="https://otpanda.github.io/app/social-preview-v4.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Otty the panda beside OTPanda, your private code space. Development preview.">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="OTPanda">
<meta name="twitter:description" content="{description}">
<meta name="twitter:image" content="https://otpanda.github.io/app/social-preview-v4.png">
<meta name="twitter:image:alt" content="Otty the panda beside OTPanda. Development preview.">
</head><body><script src="recovery-bridge.js"></script><script src="realtime-client.js"></script><script src="native-launch-intent.js"></script><script src="extension-launch-intent.js"></script><script src="assignment-host.js"></script><script src="session-bootstrap.js"></script><script src="flutter_bootstrap.js" async></script></body></html>
''')
p=Path('android/app/src/main/AndroidManifest.xml');s=p.read_text().replace('android:label="otpanda_client"','android:label="OTPanda" android:description="@string/app_description"');p.write_text(s)
write('android/app/src/main/res/values/otpanda.xml',b'<resources><string name="app_description">OTPanda development preview. Real sign-in and sources are not connected yet.</string><color name="launcher_background">#10B981</color></resources>')
for density,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
 icon(f'android/app/src/main/res/mipmap-{density}/ic_launcher.png',size)
# All art lies inside the adaptive safe zone (background and art are inset again).
icon('android/app/src/main/res/drawable/launcher_foreground.png',432)
write('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',b'<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@color/launcher_background"/><foreground android:drawable="@drawable/launcher_foreground"/></adaptive-icon>')
p=Path('linux/runner/my_application.cc');s=p.read_text().replace('"otpanda_client"','"OTPanda"');p.write_text(s)
p=Path('windows/runner/main.cpp');s=p.read_text().replace('L"otpanda_client"','L"OTPanda"');p.write_text(s)
p=Path('windows/runner/Runner.rc');s=p.read_text().replace('"FileDescription", "otpanda_client"','"FileDescription", "OTPanda development preview"').replace('"ProductName", "otpanda_client"','"ProductName", "OTPanda"');p.write_text(s)
# ICO supports PNG frames.
png=base64.b64decode(ICONS[256]);write('windows/runner/resources/app_icon.ico',struct.pack('<HHH',0,1,1)+struct.pack('<BBBBHHII',0,0,0,0,1,32,len(png),22)+png)
p=Path('macos/Runner/Configs/AppInfo.xcconfig');s=p.read_text().replace('PRODUCT_NAME = otpanda_client','PRODUCT_NAME = OTPanda');p.write_text(s)
for size in (16,32,64,128,256,512,1024):
 source=size
 icon(f'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png',source)
