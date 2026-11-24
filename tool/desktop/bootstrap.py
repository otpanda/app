#!/usr/bin/env python3
"""Generate reviewed disposable desktop hosts without mobile toolchain setup."""
import pathlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temp:
    host = pathlib.Path(temp) / 'host'
    subprocess.run(['flutter', 'create', '--platforms=linux,windows,macos',
                    '--org', 'org.otpanda.development', '--project-name',
                    'otpanda_client', str(host)], check=True)
    for platform in ('linux', 'windows', 'macos'):
        destination = root / platform
        if destination.exists():
            raise SystemExit('Use a fresh checkout: generated desktop host already exists')
        shutil.copytree(host / platform, destination)
subprocess.run(['flutter', 'pub', 'get'], cwd=root, check=True)
