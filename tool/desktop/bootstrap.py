#!/usr/bin/env python3
"""Generate disposable pinned-SDK desktop hosts without mobile toolchain setup."""
import pathlib, shutil, subprocess, tempfile, sys
flutter = shutil.which('flutter')
if flutter is None:
    raise SystemExit('Flutter executable is not on PATH')
root = pathlib.Path(__file__).resolve().parents[2]
platforms = ('linux', 'windows', 'macos')
if any((root / name).exists() for name in platforms):
    raise SystemExit('Use a fresh checkout: generated desktop host already exists')
with tempfile.TemporaryDirectory() as temp:
    host = pathlib.Path(temp) / 'host'
    subprocess.run([flutter, 'create', '--platforms=linux,windows,macos',
                    '--org', 'org.otpanda.development', '--project-name',
                    'otpanda_client', str(host)], check=True)
    for platform in platforms:
        destination = root / platform
        shutil.copytree(host / platform, destination)
# Windows wrapping-key overlay (direct DPAPI). Aborts if the template changed.
subprocess.run([sys.executable, str(root / 'tool' / 'desktop' / 'windows_overlay.py'),
                str(root)], check=True)
for decoder in ('decode_fonts.py', 'decode_zxing.py'):
    subprocess.run([sys.executable, str(root / 'tool' / decoder)], cwd=root, check=True)
subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, check=True)
