#!/usr/bin/env python3
"""Verifier for the joined loopback run: device checks from the fixture log plus the host's own non-secret state after each phase."""
from pathlib import Path
import json,sys
common=['phase_complete']
LABELS={
 'create':['admission_created','custody_enabled_by_admission','enroll_confirmed','server_one_active_key','pull_synced','rfc_code_from_real_download'],
 'restart':['install_survives_restart','code_after_restart','server_key_active_by_signed_status','enroll_already_confirmed_no_network'],
}
UI='Synthetic loopback seed host check'
def verify(p):
 p=Path(p)
 for phase,labels in LABELS.items():
  text=(p/f'{phase}.log').read_text()
  assert ' false' not in text,f'{phase}: failed check'
  for label in common+labels: assert text.count(f'CHECK {label} true')==1,f'{phase}: missing/duplicate {label}'
  ui=(p/f'ui-{phase}.xml').read_text()
  assert UI in ui and not any(s in ui for s in ("isn't responding",'is not responding')),f'{phase}: fixture frame obscured or not ready'
  assert 'FATAL EXCEPTION' not in (p/f'crash-{phase}.txt').read_text(),f'{phase}: Android crash'
  st=json.loads((p/f'server-state-{phase}.json').read_text())
  # Exactly one enrollment and one passkey ceremony in the whole run: the restart phase must not run a ceremony (explicit gesture only, no startup prompt).
  assert len(st.get('keys',[]))==1 and not st['keys'][0]['revoked'],f'{phase}: server key state'
  assert st.get('notices')==1,f'{phase}: notice count'
  assert st.get('assertionsSigned')==1,f'{phase}: assertions signed {st.get("assertionsSigned")}'
  s=st.get('seeds',[])
  assert len(s)==1 and s[0]['entry_id']=='sealed-entry' and s[0]['seed_version']>=1,f'{phase}: seeds'
  blob=json.dumps(st)
  assert 'otpda_' not in blob and 'secret' not in blob.lower(),f'{phase}: host state leaks token or secret field'
 init=json.loads((p/'server-state-initial.json').read_text())
 assert init.get('keys')==[] and init.get('assertionsSigned')==0,'host not fresh at start'
 print('PASS joined run: production enrollment+pull coordinators against the real API runtime over adb reverse loopback, one active server key, one synthetic assertion, RFC code from the real sealed download, restart and signed status. Synthetic authenticator and owner only; NOT the OS credential prompt, no root admission gate, no real account.')
if __name__=='__main__': verify(sys.argv[1])
