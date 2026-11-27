#!/usr/bin/env python3
"""Marker guard negative controls, synthetic ZIPs only, not APK evidence."""
import ast, pathlib, subprocess, sys, tempfile, zipfile
check = pathlib.Path(__file__).with_name('check_release.py')
markers = next(ast.literal_eval(n.value) for n in ast.parse(check.read_text()).body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'markers' for t in n.targets))
with tempfile.TemporaryDirectory() as d:
    apk = pathlib.Path(d) / 'synthetic.apk'
    def run(data):
        with zipfile.ZipFile(apk, 'w') as z: z.writestr('classes.dex', data)
        return subprocess.run([sys.executable, str(check), str(apk)], capture_output=True).returncode
    assert run(b'app.otpanda/import-file ImportPickerHost') == 0
    for m in markers:
        for enc in ('utf-8', 'utf-16le'):
            assert run(m.encode(enc)) != 0, m
# production sources must not carry fixture markers or the fixture's channel
root = pathlib.Path(__file__).resolve().parents[1]
for f in [root / 'DocumentImport.kt', root / 'host' / 'ImportPickerHost.kt']:
    t = f.read_text()
    assert not any(m in t for m in markers), f'fixture marker in production source {f.name}'
print('PASS release marker negative controls in both encodings, production sources free of fixture markers')
