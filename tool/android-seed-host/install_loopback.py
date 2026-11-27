# Debug fixture only. Never widens production network policy.
from pathlib import Path
p=Path('android/app/src/debug/AndroidManifest.xml');s=p.read_text()
if 'android:networkSecurityConfig' not in s:
 s=s.replace('<application', '<application android:networkSecurityConfig="@xml/seed_loopback_network"',1)
p.write_text(s)
r=Path('android/app/src/debug/res/xml/seed_loopback_network.xml');r.parent.mkdir(parents=True,exist_ok=True)
r.write_text('<network-security-config><base-config cleartextTrafficPermitted="false"/><domain-config cleartextTrafficPermitted="true"><domain>127.0.0.1</domain></domain-config></network-security-config>')
print('Installed debug-only localhost network policy')
