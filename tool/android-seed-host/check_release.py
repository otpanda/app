#!/usr/bin/env python3
"""Actual release APK must exclude every debug seed fixture marker.
R8 may rename classes, but the MethodChannel registration needs its exact string.
This is marker exclusion, not a general decompilation/security proof.
"""
import sys,zipfile
from pathlib import Path
apk=Path(sys.argv[1])
markers=['SyntheticSeedSealer','SeedHostActivity','app/otpanda/seedfixture','app.otpanda.seedfixture','seedfx/driver','fixture-owner','seedfx-public']
with zipfile.ZipFile(apk) as z:
 for name in z.namelist():
  if name.endswith('/'):continue
  data=z.read(name)
  assert not any(m.encode() in data or m.encode('utf-16le') in data for m in markers), f'debug fixture marker in {name}'
print('PASS actual release APK excludes all seed debug fixture markers; reviewed production channels may be present')
