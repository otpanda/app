#!/usr/bin/env python3
"""Copy the Android import-picker sources into a generated Android host.

Usage: android_import_picker_overlay.py [repo_root] [--register]

Run after tool/android_native_overlay.py. Copies the Kotlin core into org.otpanda.documentimport and ImportPickerHost into
app.otpanda. It adds no dependency, permission or manifest change (ACTION_OPEN_DOCUMENT needs none). Nothing is registered
unless --register is passed: that inserts one anchored line into the generated MainActivity.kt (exactly one anchor match, or
it aborts with no edits). Test files are never copied into the app.
"""
import pathlib
import shutil
import sys

CORE = ('DocumentImport.kt',)
HOST = 'ImportPickerHost.kt'
ANCHOR = '        WrappingKeyHost.register(this, flutterEngine.dartExecutor.binaryMessenger)\n'
LINE = '        ImportPickerHost.register(flutterEngine)\n'


def apply(root, register=False):
    root = pathlib.Path(root)
    src = root / 'tool' / 'android-import-picker'
    kotlin = root / 'android' / 'app' / 'src' / 'main' / 'kotlin'
    activity = kotlin / 'app' / 'otpanda' / 'MainActivity.kt'
    if not activity.is_file():
        raise SystemExit(f'missing generated file: {activity}')
    new_activity = None
    if register:
        text = activity.read_text()
        if 'ImportPickerHost.register' in text:
            raise SystemExit('already registered')
        if text.count(ANCHOR) != 1:
            raise SystemExit(f'MainActivity.kt: anchor not found exactly once: {ANCHOR!r}')
        new_activity = text.replace(ANCHOR, ANCHOR + LINE)
    for name in CORE:
        if not (src / name).is_file():
            raise SystemExit(f'missing source: {src / name}')
    if not (src / 'host' / HOST).is_file():
        raise SystemExit(f'missing source: {src / "host" / HOST}')
    core_dir = kotlin / 'org' / 'otpanda' / 'documentimport'
    core_dir.mkdir(parents=True, exist_ok=True)
    for name in CORE:
        shutil.copyfile(src / name, core_dir / name)
    shutil.copyfile(src / 'host' / HOST, kotlin / 'app' / 'otpanda' / HOST)
    if new_activity is not None:
        activity.write_text(new_activity)


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    for a in sys.argv[1:]:
        if a.startswith('--') and a != '--register':
            raise SystemExit(f'unknown option: {a}')
    apply(args[0] if args else pathlib.Path(__file__).resolve().parents[1], '--register' in sys.argv)
