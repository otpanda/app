#!/usr/bin/env python3
"""Marker guard negative controls, synthetic ZIPs only, not APK evidence."""
import ast, pathlib, subprocess, sys, tempfile, zipfile
check = pathlib.Path(__file__).with_name('check_release.py')
module = ast.parse(check.read_text())
markers = next(ast.literal_eval(n.value) for n in module.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'markers' for t in n.targets))
with tempfile.TemporaryDirectory() as d:
    apk = pathlib.Path(d)/'synthetic.apk'
    def run(data):
        with zipfile.ZipFile(apk,'w') as z: z.writestr('classes.dex',data)
        return subprocess.run([sys.executable,str(check),str(apk)],capture_output=True).returncode
    assert run(b'app.otpanda/seed-custody app.otpanda/workspace-admission app.otpanda/wrapping-key') == 0
    for marker in markers:
        for encoding in ['utf-8','utf-16le']:
            assert run(marker.encode(encoding)) != 0, marker
print('PASS release marker negative controls in both encodings')
