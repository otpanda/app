#!/usr/bin/env python3
"""Negative check: a release artifact must contain NO fixture, synthetic provider or fake API class/dex/manifest/resource string.
Usage: check-release-artifact.py APK|AAB|ZIP|DIR   (exit 1 if any marker is found)
       check-release-artifact.py --expect-present APK   (positive control on the DEBUG apk: exit 1 unless ALL class markers are found)
Scans every zip entry (dex, binary manifest as UTF-16 too, resources) and directory file bytes."""
import sys, zipfile
from pathlib import Path
CLASSES = ['LockPromptHostActivity', 'SyntheticProviderService', 'SyntheticAssertionActivity', 'FakeLockApi']
OTHER = ['app/otpanda/fixture', 'app.otpanda.fixture', 'lockfx_provider', 'fixture-bearer-not-a-real-token', 'fixture-device-not-real', 'lockfx/driver', 'synthetic-fixture-credential']
def blobs(p):
    p = Path(p)
    if p.is_dir():
        for f in p.rglob('*'):
            if f.is_file(): yield str(f), f.read_bytes()
    else:
        with zipfile.ZipFile(p) as z:
            for n in z.namelist():
                if not n.endswith('/'): yield n, z.read(n)
def hits(path, needles):
    found = {}
    for name, data in blobs(path):
        for n in needles:
            if n.encode() in data or n.encode('utf-16le') in data: found.setdefault(n, []).append(name)
    return found
def main():
    a = sys.argv[1:]
    present = '--expect-present' in a; a = [x for x in a if x != '--expect-present']
    if len(a) != 1: sys.exit('usage: check-release-artifact.py [--expect-present] APK|DIR')
    if present:
        f = hits(a[0], CLASSES); miss = [c for c in CLASSES if c not in f]
        if miss: print('MISSING (positive control failed):', ', '.join(miss)); sys.exit(1)
        print('positive control ok:', ', '.join(CLASSES)); return
    f = hits(a[0], CLASSES + OTHER)
    if f:
        for k, v in f.items(): print('FOUND', k, 'in', ', '.join(sorted(set(v))[:3]))
        sys.exit(1)
    print('PASS no fixture markers in', a[0])
if __name__ == '__main__': main()
