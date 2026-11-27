#!/usr/bin/env python3
from pathlib import Path
import sys
p=Path(sys.argv[1])
common=['install_id_valid','signature_verifies','wrong_key_refused','phase_complete']
extra={'create':['fresh_owner','enroll_public_only','install_mismatch_refused','fresh_provable','typed_batch_sign','typed_batch_skip','typed_batch_finish','sealed_tamper_refused','tamper_no_custody','sealed_open_complete','sealed_rfc_code','workspace_one_create','workspace_retry_no_create','workspace_database_open','workspace_encrypted_disk','workspace_local_code','workspace_snapshot_replay'], 'restart':['install_survives_restart','durable_key_state_after_restart','durable_discovery','erase_complete','erase_no_active_key','shared_custody_disabled','install_survives_erase','sealed_restart_code','sealed_erased_unusable','workspace_cold_scope','workspace_database_open','workspace_cold_metadata','workspace_local_code','workspace_lock_hides','workspace_disabled_discovery_refused','workspace_snapshot_replay','workspace_changed_replay_refused','workspace_unsupported_preserved']}
for phase, labels in extra.items():
 text=(p/f'{phase}.log').read_text()
 assert ' false' not in text, f'{phase}: failed check'
 for label in common+labels: assert text.count(f'CHECK {label} true')==1, f'{phase}: missing/duplicate {label}'
 ui=(p/f'ui-{phase}.xml').read_text()
 assert ('Synthetic offline service' if phase == 'create' else 'Synthetic seed host check') in ui and not any(s in ui for s in ("isn't responding", 'is not responding')), f'{phase}: fixture frame obscured or not ready'
 assert 'FATAL EXCEPTION' not in (p/f'crash-{phase}.txt').read_text(), f'{phase}: Android crash'
print('PASS real Flutter channel, composed shared custody/install/sync host, AndroidKeystore enrollment/signature, restart and disable; synthetic owner only, local sealed seed path only, no continued enrollment proof, server confirmation, remote API sync or physical provider proof')
