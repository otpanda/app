#!/usr/bin/env python3
"""Fails unless the given AndroidManifest.xml files (source, or the merged
manifest of a debug/release build) disable backup and point at rules that
exclude every storage domain for cloud backup and device transfer.
Usage: check-android-backup.py MANIFEST... [--res android/app/src/main/res]
Not a guarantee about any OEM transfer tool: it checks what this app declares."""
import re, sys
from pathlib import Path
DOMAINS = {'file', 'database', 'sharedpref', 'external', 'root',
           'device_file', 'device_database', 'device_sharedpref', 'device_root'}
args = sys.argv[1:]
res = Path('android/app/src/main/res')
if '--res' in args:
    i = args.index('--res'); res = Path(args[i + 1]); del args[i:i + 2]
if not args:
    sys.exit('no manifest given')
bad = []
def excluded(section_text):
    return {m.group(1) for m in re.finditer(
        r'<exclude\s+domain="([a-z_]+)"\s+path="\.?"\s*/>', section_text)}
for mf in args:
    t = Path(mf).read_text()
    m = re.search(r'<application\b[^>]*>', t, re.S)
    tag = m.group(0) if m else ''
    if 'android:allowBackup="false"' not in tag:
        bad.append(f'{mf}: allowBackup is not "false"')
    for attr, name in (('dataExtractionRules', 'data_extraction_rules'),
                       ('fullBackupContent', 'backup_rules')):
        if f'android:{attr}="@xml/{name}"' not in tag and f'android:{attr}=' not in tag:
            bad.append(f'{mf}: android:{attr} missing')
for name, sections in (('data_extraction_rules', ('cloud-backup', 'device-transfer')),
                       ('backup_rules', (None,))):
    f = res / 'xml' / f'{name}.xml'
    if not f.exists():
        bad.append(f'{f} missing'); continue
    t = f.read_text()
    if re.search(r'<include\b', t):
        bad.append(f'{f}: has an include rule')
    for sec in sections:
        body = t if sec is None else (re.search(rf'<{sec}>(.*?)</{sec}>', t, re.S) or [None, ''])[1]
        miss = DOMAINS - excluded(body)
        if miss:
            bad.append(f'{f}: {sec or "full-backup-content"} does not exclude {sorted(miss)}')
if bad:
    print('\n'.join(bad)); sys.exit(1)
print('backup exclusions OK for', ', '.join(args))
