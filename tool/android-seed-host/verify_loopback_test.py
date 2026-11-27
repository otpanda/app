#!/usr/bin/env python3
"""Negative controls for verify_loopback.py with synthetic logs, not Android evidence."""
from pathlib import Path
import importlib.util,json,tempfile
spec=importlib.util.spec_from_file_location('v',Path(__file__).with_name('verify_loopback.py'));v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
STATE={'keys':[{'keyId':'a'*32,'revoked':False}],'notices':1,'assertionsSigned':1,'seeds':[{'entry_id':'sealed-entry','seed_version':1}]}
with tempfile.TemporaryDirectory() as t:
 p=Path(t)
 def reset():
  for phase,ls in v.LABELS.items():
   (p/f'{phase}.log').write_text('\n'.join(f'CHECK {x} true' for x in ls+v.common))
   (p/f'crash-{phase}.txt').write_text('');(p/f'ui-{phase}.xml').write_text(f'<node text="{v.UI}"/>')
   (p/f'server-state-{phase}.json').write_text(json.dumps(STATE))
  (p/'server-state-initial.json').write_text(json.dumps({'keys':[],'assertionsSigned':0}))
 def ok():
  try: v.verify(p); return True
  except AssertionError: return False
 reset();assert ok()
 for phase,ls in v.LABELS.items():
  for label in ls+v.common:
   reset();f=p/f'{phase}.log';f.write_text(f.read_text().replace(f'CHECK {label} true',''));assert not ok(),label
   reset();f.write_text(f.read_text()+f'\nCHECK {label} true');assert not ok(),label
  reset();f=p/f'{phase}.log';f.write_text(f.read_text()+'\nCHECK phase_failed false');assert not ok()
  reset();(p/f'crash-{phase}.txt').write_text('FATAL EXCEPTION');assert not ok()
  reset();(p/f'ui-{phase}.xml').write_text('<node text="x"/>');assert not ok()
  for k,val in [('assertionsSigned',2),('assertionsSigned',0),('notices',0),('keys',[]),('keys',[{'keyId':'a'*32,'revoked':True}]),('seeds',[]),('token','otpda_x')]:
   reset();(p/f'server-state-{phase}.json').write_text(json.dumps({**STATE,k:val}));assert not ok(),(phase,k)
 reset();(p/'server-state-initial.json').write_text(json.dumps({'keys':[{}],'assertionsSigned':0}));assert not ok()
print('PASS loopback verifier negative controls: every missing/duplicate label, failure, crash, wrong UI, extra ceremony, key/notice/seed state, leaked token')
