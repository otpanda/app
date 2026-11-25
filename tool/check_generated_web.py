"""Fail CI when the compiled web package carries stale session scripts."""
from pathlib import Path

for name in ('session-bootstrap.js', 'realtime-client.js', 'recovery-bridge.js', 'extension-launch-intent.js'):
    source = Path('tool') / name
    for folder in ('web', 'build/web'):
        generated = Path(folder) / name
        if not generated.is_file() or generated.read_bytes() != source.read_bytes():
            raise SystemExit(f'Stale generated asset: {generated}; run tool/bootstrap.sh before building')
print('Generated web scripts match exact source bytes')

import subprocess
expected = subprocess.check_output(['node', '--input-type=module', '-e',
    "import {bundleAssignment} from './tool/build-assignment-host.mjs';process.stdout.write(await bundleAssignment());"])
for folder in ('web', 'build/web'):
    generated = Path(folder) / 'assignment-host.js'
    if not generated.is_file() or generated.read_bytes() != expected:
        raise SystemExit(f'Stale generated assignment host: {generated}; run tool/bootstrap.sh before building')
print('Generated assignment host matches exact controller and transport bytes')
