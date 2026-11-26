#!/usr/bin/env python3
"""Rebuild PNGs from SHOTPART lines in a flutter test log: extract-shots.py LOG OUTDIR"""
import base64, os, re, sys
parts = {}
for line in open(sys.argv[1], errors='replace'):
    m = re.search(r'SHOTPART:([\w-]+):(\d+):(\d+):([A-Za-z0-9+/=]+)', line)
    if m:
        parts.setdefault(m[1], {})[int(m[2])] = (int(m[3]), m[4])
os.makedirs(sys.argv[2], exist_ok=True)
for name, p in parts.items():
    total = next(iter(p.values()))[0]
    if sorted(p) != list(range(total)):
        print('incomplete', name); continue
    open(f'{sys.argv[2]}/{name}.png', 'wb').write(base64.b64decode(''.join(p[i][1] for i in range(total))))
    print('wrote', name)
