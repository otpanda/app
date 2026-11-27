#!/usr/bin/env python3
"""Release APK must exclude every debug picker fixture marker. Marker exclusion only, not a general security proof.
The production import channel (app.otpanda/import-file) may be present."""
import sys, zipfile
from pathlib import Path
markers = ['SyntheticDocumentsProvider', 'PickerFixtureActivity', 'app/otpanda/pickerfx', 'app.otpanda.pickerfx', 'pickfx/driver', 'pickfx-phase', 'fixture-a.txt', 'OTPanda picker fixture']
with zipfile.ZipFile(Path(sys.argv[1])) as z:
    for name in z.namelist():
        if name.endswith('/'):
            continue
        data = z.read(name)
        assert not any(m.encode() in data or m.encode('utf-16le') in data for m in markers), f'debug picker fixture marker in {name}'
print('PASS release APK excludes all picker debug fixture markers; production import channel may be present')
