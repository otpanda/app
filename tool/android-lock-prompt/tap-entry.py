#!/usr/bin/env python3
"""Reads a uiautomator dump XML and prints the center "x y" of the first node whose text or content-desc contains any needle (case-insensitive).
Exit 1 when none. Usage: tap-entry.py dump.xml needle [needle...]"""
import re, sys
import xml.etree.ElementTree as ET
def find(path, needles):
    try: root = ET.parse(path).getroot()
    except Exception: return None
    for n in root.iter('node'):
        label = (n.get('text', '') + '\n' + n.get('content-desc', '')).lower()
        if any(x.lower() in label for x in needles):
            m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds', ''))
            if m:
                a, b, c, d = map(int, m.groups())
                if c > a and d > b: return (a + c) // 2, (b + d) // 2
    return None
if __name__ == '__main__':
    r = find(sys.argv[1], sys.argv[2:])
    if not r: sys.exit(1)
    print(*r)
