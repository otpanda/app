#!/usr/bin/env python3
import base64,gzip,hashlib
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'assets/zxing/zxing-library-0.23.0.min.js'
data=gzip.decompress(base64.b64decode(Path(str(p)+'.gz.b64').read_text().strip(),validate=True))
assert hashlib.sha256(data).hexdigest()=='3ede94153fb0c5b67a12d7adff6decd827c2b22714fdc6faecf27a8f20937ea6', 'ZXing source hash mismatch'
p.write_bytes(data)
