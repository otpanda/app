#!/usr/bin/env python3
"""Reads a uiautomator dump XML and prints the center "x y" of the first node whose text or content-desc contains any needle (case-insensitive).
Exit 1 when none. Usage: tap-entry.py [--exact-clickable] dump.xml needle [needle...]
--exact-clickable: only a node with clickable="true" whose whole text or content-desc equals a needle (case-insensitive).
The synthetic entry search stays "contains" (the label sits in a row container)."""
import re, sys
import xml.etree.ElementTree as ET
def find(path, needles, exact=False):
    try: root = ET.parse(path).getroot()
    except Exception: return None
    for n in root.iter('node'):
        label = (n.get('text', '') + '\n' + n.get('content-desc', '')).lower()
        if exact:
            whole = {n.get('text', '').strip().lower(), n.get('content-desc', '').strip().lower()}
            hit = n.get('clickable') == 'true' and any(x.lower() in whole for x in needles)
        else: hit = any(x.lower() in label for x in needles)
        if hit:
            m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds', ''))
            if m:
                a, b, c, d = map(int, m.groups())
                if c > a and d > b: return (a + c) // 2, (b + d) // 2
    return None
if __name__ == '__main__':
    a = sys.argv[1:]; ex = a[0] == '--exact-clickable'
    if ex: a = a[1:]
    r = find(a[0], a[1:], ex)
    if not r: sys.exit(1)
    print(*r)
