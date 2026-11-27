#!/usr/bin/env python3
from pathlib import Path
import sys
p=Path(sys.argv[1])
common=['install_id_valid','signature_verifies','wrong_key_refused','phase_complete']
extra={'create':['fresh_owner','enroll_public_only','install_mismatch_refused','fresh_provable'], 'restart':['install_survives_restart','durable_key_state_after_restart','durable_discovery','erase_complete','erase_no_active_key','shared_custody_disabled','install_survives_erase']}
for phase, labels in extra.items():
 text=(p/f'{phase}.log').read_text()
 assert ' false' not in text, f'{phase}: failed check'
 for label in common+labels: assert text.count(f'CHECK {label} true')==1, f'{phase}: missing/duplicate {label}'
 ui=(p/f'ui-{phase}.xml').read_text()
 assert 'Synthetic seed host check' in ui and 'isn' not in ui, f'{phase}: fixture frame obscured or not ready'
 assert 'FATAL EXCEPTION' not in (p/f'crash-{phase}.txt').read_text(), f'{phase}: Android crash'
print('PASS real Flutter channel, composed shared custody/install/sync host, AndroidKeystore enrollment/signature, restart and disable; synthetic owner only, no continued enrollment proof, server confirmation, seed sync, API or provider proof')
