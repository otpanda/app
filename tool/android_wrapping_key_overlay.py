#!/usr/bin/env python3
"""Copy the Android wrapping-key sources into a generated Android host.

Usage: android_wrapping_key_overlay.py [repo_root] [--register]

Run after tool/android_native_overlay.py. Copies the Kotlin core, Keystore wrapper
and channel handler into org.otpanda.wrappingkey and WrappingKeyHost into
app.otpanda. It adds no dependency, permission or manifest change. Nothing is
registered unless --register is passed: that inserts one anchored line into the
generated MainActivity.kt (exactly one anchor match or it aborts with no edits).
Test, child-process and test-support files are never copied into the app.
"""
import pathlib
import shutil
import sys

CORE = ('WrappingKey.kt', 'WrappingKeyChannel.kt', 'WrappingKeyAndroid.kt')
HOST = 'WrappingKeyHost.kt'
ANCHOR = '        DeviceProofHost.register(this, flutterEngine.dartExecutor.binaryMessenger)\n'
LINE = '        WrappingKeyHost.register(this, flutterEngine.dartExecutor.binaryMessenger)\n'


def apply(root, register=False):
    root = pathlib.Path(root)
    src = root / 'tool' / 'android-wrapping-key'
    kotlin = root / 'android' / 'app' / 'src' / 'main' / 'kotlin'
    activity = kotlin / 'app' / 'otpanda' / 'MainActivity.kt'
    if not activity.is_file():
        raise SystemExit(f'missing generated file: {activity}')
    new_activity = None
    if register:
        text = activity.read_text()
        if 'WrappingKeyHost.register' in text:
            raise SystemExit('already registered')
        if text.count(ANCHOR) != 1:
            raise SystemExit(f'MainActivity.kt: anchor not found exactly once: {ANCHOR!r}')
        new_activity = text.replace(ANCHOR, ANCHOR + LINE)
    for name in CORE:
        if not (src / name).is_file():
            raise SystemExit(f'missing source: {src / name}')
    if not (src / 'host' / HOST).is_file():
        raise SystemExit(f'missing source: {src / "host" / HOST}')
    core_dir = kotlin / 'org' / 'otpanda' / 'wrappingkey'
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
