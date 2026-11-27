#!/usr/bin/env python3
"""Verifier controls with synthetic logs, not Android evidence."""
from pathlib import Path
import tempfile,subprocess,sys
v=Path(__file__).with_name('verify.py')
common=['install_id_valid','signature_verifies','wrong_key_refused','phase_complete']
labels={'create':common+['fresh_owner','enroll_public_only','install_mismatch_refused','fresh_provable'],'restart':common+['install_survives_restart','durable_key_state_after_restart','durable_discovery','erase_complete','erase_no_active_key','shared_custody_disabled','install_survives_erase']}
with tempfile.TemporaryDirectory() as t:
 p=Path(t)
 def reset():
  for phase,ls in labels.items():
   (p/f'{phase}.log').write_text('\n'.join(f'CHECK {x} true' for x in ls))
   (p/f'crash-{phase}.txt').write_text('')
 def ok():return subprocess.run([sys.executable,str(v),t],capture_output=True).returncode==0
 reset();assert ok()
 for phase,ls in labels.items():
  for label in ls:
   reset(); f=p/f'{phase}.log';f.write_text(f.read_text().replace(f'CHECK {label} true',''));assert not ok()
   reset();f.write_text(f.read_text()+f'\nCHECK {label} true');assert not ok()
  reset();f=p/f'{phase}.log';f.write_text(f.read_text()+'\nCHECK phase_failed false');assert not ok()
  reset();(p/f'crash-{phase}.txt').write_text('FATAL EXCEPTION');assert not ok()
 print('PASS verifier negative controls: every missing/duplicate label, failed check, Android crash')
