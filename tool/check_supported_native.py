"""Prevent supported native features becoming opt-in release switches again."""
from pathlib import Path
names=['NATIVE_'+'SIGNIN','NATIVE_'+'ENTRY_EDIT_ENABLED','NATIVE_'+'SETTINGS_ENABLED','NATIVE_'+'ENTRY_DOMAINS_ENABLED']
for root in ['lib','test','integration_test','tool','.github']:
 for p in Path(root).rglob('*'):
  if not p.is_file() or p.name=='check_supported_native.py' or p.suffix not in {'.dart','.sh','.yml','.yaml','.md','.py'}:continue
  text=p.read_text()
  assert not any(name in text for name in names),f'obsolete supported-feature switch: {p}'
source=Path('lib/native/native_root_io.dart').read_text()
assert 'NativeBrowserFallback' not in source
assert 'settingsEnabled: true' in source and 'entryEditEnabled: true' in source and 'entryDomainsEnabled: true' in source
print('Supported native features have no opt-in build switches')
