#!/usr/bin/env python3
"""Verifier controls with synthetic logs, not Android evidence."""
from pathlib import Path
import tempfile,subprocess,sys
v=Path(__file__).with_name('verify.py')
common=['install_id_valid','signature_verifies','wrong_key_refused','phase_complete']
labels={'create':common+['fresh_owner','enroll_public_only','install_mismatch_refused','fresh_provable','typed_batch_sign','typed_batch_skip','typed_batch_finish','sealed_tamper_refused','tamper_no_custody','sealed_open_complete','sealed_rfc_code'],'restart':common+['install_survives_restart','durable_key_state_after_restart','durable_discovery','erase_complete','erase_no_active_key','shared_custody_disabled','install_survives_erase','sealed_restart_code','sealed_erased_unusable']}
with tempfile.TemporaryDirectory() as t:
 p=Path(t)
 def reset():
  for phase,ls in labels.items():
   (p/f'{phase}.log').write_text('\n'.join(f'CHECK {x} true' for x in ls))
   (p/f'crash-{phase}.txt').write_text('')
   (p/f'ui-{phase}.xml').write_text('<node text="Synthetic seed host check"/>')
 def ok():return subprocess.run([sys.executable,str(v),t],capture_output=True).returncode==0
 reset();assert ok()
 for phase,ls in labels.items():
  for label in ls:
   reset(); f=p/f'{phase}.log';f.write_text(f.read_text().replace(f'CHECK {label} true',''));assert not ok()
   reset();f.write_text(f.read_text()+f'\nCHECK {label} true');assert not ok()
  reset();f=p/f'{phase}.log';f.write_text(f.read_text()+'\nCHECK phase_failed false');assert not ok()
  reset();(p/f'crash-{phase}.txt').write_text('FATAL EXCEPTION');assert not ok()
  reset();(p/f'ui-{phase}.xml').write_text('<node text="missing fixture"/>');assert not ok()
  for anr in ["isn't responding", 'is not responding']:
   reset();(p/f'ui-{phase}.xml').write_text(f'<node text="Synthetic seed host check"/><node text="Pixel Launcher {anr}"/>');assert not ok()
 print('PASS verifier negative controls: every missing/duplicate label, failed check, Android crash')
