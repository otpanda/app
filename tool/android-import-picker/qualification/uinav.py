"""Pure helpers for driving the system document picker from uiautomator dumps. No device access."""
import re
import xml.etree.ElementTree as ET

ROOT_TITLE = 'OTPanda picker fixture'


def _center(node):
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds') or '')
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


def _find(xml, text=None, desc=None):
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return None
    for n in root.iter('node'):
        if text is not None and n.get('text') == text and _center(n):
            return _center(n)
        if desc is not None and (n.get('content-desc') or '').lower() == desc.lower() and _center(n):
            return _center(n)
    return None


def next_action(xml, doc_name, root_title=ROOT_TITLE):
    """What to tap next: the document if listed, else the provider root, else the roots menu."""
    for kind, args in (('doc', {'text': doc_name}), ('root', {'text': root_title}), ('menu', {'desc': 'Show roots'})):
        c = _find(xml, **args)
        if c:
            return kind, c[0], c[1]
    return None


def focus_is_picker(dumpsys_window):
    """True when the focused window is the system documents UI (not the app, a launcher, an ANR or the keyguard)."""
    for line in dumpsys_window.splitlines():
        if 'mCurrentFocus' in line:
            return 'documentsui' in line.lower()
    return False
