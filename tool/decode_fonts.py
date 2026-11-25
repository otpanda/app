"""Restore pinned OFL font assets from checked-in lossless text sources, without network access."""
import base64
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parent.parent / 'assets/fonts'
for item in json.loads((root / 'SHA256SUMS.json').read_text()):
    name = item['file']
    if Path(name).name != name:
        raise ValueError('Invalid font source name')
    content = base64.b64decode((root / (name + '.b64')).read_text().strip(), validate=True)
    if hashlib.sha256(content).hexdigest() != item['sha256']:
        raise ValueError('Font source hash mismatch: ' + name)
    target = root / name
    if not target.exists() or target.read_bytes() != content:
        target.write_bytes(content)
