"""Fail closed before fixture installation. Hash source and exact generated production hosts."""
from pathlib import Path
import hashlib,json,sys
pairs=[
 ('tool/android-native/main/ImportJournalHost.kt','android/app/src/main/kotlin/app/otpanda/ImportJournalHost.kt'),
 ('tool/android-native/main/MainActivity.kt','android/app/src/main/kotlin/app/otpanda/MainActivity.kt'),
 ('tool/android-import-picker/host/ImportPickerHost.kt','android/app/src/main/kotlin/app/otpanda/ImportPickerHost.kt'),
 ('tool/android-import-picker/DocumentImport.kt','android/app/src/main/kotlin/org/otpanda/documentimport/DocumentImport.kt'),
]
rows=[]
for source,generated in pairs:
 a,b=Path(source).read_bytes(),Path(generated).read_bytes()
 row={'source':source,'generated':generated,'source_sha256':hashlib.sha256(a).hexdigest(),'generated_sha256':hashlib.sha256(b).hexdigest(),'equal':a==b}
 rows.append(row)
Path(sys.argv[1]).write_text(json.dumps(rows,indent=2))
assert all(r['equal'] for r in rows),'Generated host mismatch, refusing qualification'
print('PASS exact generated/source host SHA256 comparison')
