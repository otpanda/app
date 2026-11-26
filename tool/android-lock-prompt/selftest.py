#!/usr/bin/env python3
"""Positive and negative tests for verify-log.py, tap-entry.py and check-release-artifact.py with synthetic inputs (no device). Not OS evidence."""
import os, subprocess, sys, tempfile, zipfile
H = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
CM = 'com.android.credentialmanager/com.android.credentialmanager.CredentialSelectorActivity'
GMS = 'com.google.android.gms/com.google.android.gms.auth.api.credentials.credentialmanager.CredentialActivity'
SC = ['unlock_idle', 'unlock_back', 'unlock_home', 'unlock_select', 'disable_select']
def ev(e, s, **k): return f'I LOCKFX : ev={e} t=0 scenario={s} pid=1 ' + ' '.join(f'{a}={b}' for a, b in k.items())
def pe(e, **k): return f'I LOCKFX : ev={e} ' + ' '.join(f'{a}={b}' for a, b in k.items())
def mk(s, n, **k): return f'I LOCKFX : ev=mark scenario={s} name={n} ' + ' '.join(f'{a}={b}' for a, b in k.items())
OUT = {'unlock_back': 'USER_CANCELLED', 'unlock_home': 'ABORTED', 'unlock_select': 'UNLOCK_GRANTED', 'disable_select': 'DISABLED'}
def scen(s, focus=CM, entry='yes', outcome=True, home_mark=True, early_outcome=False, extra_stop=False, begin_ok='1', host='realHost=1', flag='true', selected=True, finish_ok='1', consume=('true', 'false'), flag_after='false', shot=True, provider_begin=True):
    L = [f'== scenario {s}', mk(s, 'BEGIN'), ev('onCreate', s), f'I LOCKFX : ev=host_ready t=0 scenario={s} pid=1 api=fake loopback=1 {host} flag={flag}', ev('attempt_start', s)]
    L.append(ev('fake_begin', s, ok=begin_ok, intent='local-lock-disable' if s.startswith('disable') else 'local-unlock-once'))
    if provider_begin: L.append(pe('provider_begin_get', options=1))
    if early_outcome: L.append(ev('outcome', s, value='PASSKEY_UNAVAILABLE'))
    L += [mk(s, 'FOCUS_IDLE', value=focus), mk(s, 'ENTRY_VISIBLE', value=entry)]
    if shot: L.append(mk(s, 'SHOT_OK', file='a.png'))
    if extra_stop: L.append(ev('onStop', s))
    if s == 'unlock_back': L.append(mk(s, 'BACK'))
    if s == 'unlock_home':
        if home_mark: L.append(mk(s, 'HOME'))
        L.append(ev('onStop', s))
    if s.endswith('select'):
        L.append(mk(s, 'TAP_ENTRY'))
        if selected: L.append(pe('provider_selected'))
        L.append(ev('fake_finish', s, ok=finish_ok, challenge_match=finish_ok))
    if outcome and s in OUT: L.append(ev('outcome', s, value=OUT[s]))
    if s == 'unlock_select' and consume: L.append(ev('consume_unlock', s, first=consume[0], second=consume[1]))
    if s == 'disable_select': L.append(ev('flag_after', s, present=flag_after))
    return L
def build(head=('API=34', 'ENABLE=OK'), tail=(), **over):
    L = list(head)
    for s in SC: L += scen(s, **over.get(s, {}))
    return L + list(tail)
def verify(lines, env=None):
    f = tempfile.NamedTemporaryFile('w', suffix='.log', delete=False); f.write('\n'.join(lines) + '\n'); f.close()
    r = subprocess.run([PY, f'{H}/verify-log.py', f.name, '34'], capture_output=True, text=True, env={**os.environ, **(env or {})})
    os.unlink(f.name); return r.returncode, r.stdout
ok = True
def expect(name, got, want_code, want=None, out=''):
    global ok
    good = got == want_code and (want is None or want in out)
    print(('ok  ' if good else 'BAD ') + name); ok &= good
def v(name, lines, code, want=None, env=None):
    c, out = verify(lines, env); expect(name, c, code, want, out)
v('complete log passes', build(), 0, 'SCOPE')
v('gms credential activity passes', build(unlock_idle={'focus': GMS}), 0)
v('wrong API fails', build(head=('API=33', 'ENABLE=OK')), 1)
v('no enablement readback fails', build(head=('API=34',)), 1, 'enablement')
v('provider rejected fails', build(tail=('PROVIDER_REJECTED=yes scenario=unlock_idle',)), 1, 'rejected')
v('crash fails', build(tail=('CRASH=yes',)), 1)
v('missing scenario fails', [l for l in build() if 'disable_select' not in l], 1)
v('provider never asked fails', build(unlock_idle={'provider_begin': False}), 1, 'provider_begin_get')
v('fake begin not served fails', build(unlock_idle={'begin_ok': '0'}), 1, 'fake begin')
v('not the real host fails', build(unlock_idle={'host': 'realHost=0'}), 1, 'realHost')
v('no lock flag fails', build(unlock_idle={'flag': 'false'}), 1, 'flag')
for n, f in (('app focus', 'app.otpanda/app.otpanda.fixture.LockPromptHostActivity'), ('keyguard', 'com.android.systemui/Keyguard'), ('launcher', 'com.google.android.apps.nexuslauncher/.NexusLauncherActivity'),
             ('ANR dialog', 'Application_Not_Responding__app.otpanda'), ('gms non-credential activity', 'com.google.android.gms/com.google.android.gms.update.Foo')):
    v(f'{n} focus is not a selector', build(unlock_idle={'focus': f}), 1, 'not a credential selector')
v('own entry not visible (error sheet) fails', build(unlock_idle={'entry': 'no'}), 1, 'not visible')
v('missing screenshot fails', build(unlock_idle={'shot': False}), 1, 'screenshot')
v('early outcome before idle fails', build(unlock_back={'early_outcome': True}), 1, 'before the idle check')
bb = build(); bb.insert(bb.index('== scenario unlock_idle') + 9, ev('outcome', 'unlock_idle', value='ABORTED'))
v('unlock_idle outcome (not pending) fails', bb, 1, 'must stay pending')
v('prompt-caused stop is a reported fact by default', build(unlock_idle={'extra_stop': True}), 0, 'self_stop_before_any_user_action=YES')
v('prompt-caused stop fails with REQUIRE_NO_SELF_STOP=1', build(unlock_idle={'extra_stop': True}), 1, 'REQUIRE_NO_SELF_STOP', env={'REQUIRE_NO_SELF_STOP': '1'})
v('unlock_back without outcome fails', build(unlock_back={'outcome': False}), 1, 'USER_CANCELLED')
v('unlock_home without ABORTED fails', build(unlock_home={'outcome': False}), 1, 'ABORTED')
v('unlock_home without HOME mark fails', build(unlock_home={'home_mark': False}), 1, 'no HOME mark')
v('select without provider_selected fails', build(unlock_select={'selected': False}), 1, 'not selected')
v('select with bad finish fails', build(unlock_select={'finish_ok': '0'}), 1, 'fake finish')
v('select without UNLOCK_GRANTED fails', build(unlock_select={'outcome': False}), 1, 'UNLOCK_GRANTED')
v('consumeUnlock twice true fails', build(unlock_select={'consume': ('true', 'true')}), 1, 'consumeUnlock')
v('consumeUnlock missing fails', build(unlock_select={'consume': None}), 1, 'consumeUnlock')
v('disable without DISABLED fails', build(disable_select={'outcome': False}), 1, 'DISABLED')
v('disable with flag still present fails', build(disable_select={'flag_after': 'true'}), 1, 'flag still present')
bb = build(); i = bb.index(ev('outcome', 'unlock_back', value='USER_CANCELLED')); bb.insert(i, ev('outcome', 'unlock_back', value='ABORTED'))
v('two outcomes fail', bb, 1)
# tap-entry
d = tempfile.mkdtemp(); x = f'{d}/u.xml'
open(x, 'w').write('<hierarchy><node text="Other" bounds="[0,0][10,10]"/><node text="synthetic-fixture-user" content-desc="" bounds="[100,200][300,260]"/></hierarchy>')
r = subprocess.run([PY, f'{H}/tap-entry.py', x, 'Synthetic fixture passkey', 'synthetic-fixture-user'], capture_output=True, text=True)
expect('tap-entry finds the center', (r.returncode, r.stdout.strip()), (0, '200 230'))
r = subprocess.run([PY, f'{H}/tap-entry.py', x, 'No such text'], capture_output=True, text=True); expect('tap-entry absent text exits 1', r.returncode, 1)
open(x, 'w').write('<broken'); r = subprocess.run([PY, f'{H}/tap-entry.py', x, 'a'], capture_output=True, text=True); expect('tap-entry bad xml exits 1', r.returncode, 1)
# release artifact check
def apk(name, entries):
    p = f'{d}/{name}'
    with zipfile.ZipFile(p, 'w') as z:
        for n, b in entries.items(): z.writestr(n, b)
    return p
dbg = apk('debug.apk', {'classes.dex': b'..Lapp/otpanda/fixture/LockPromptHostActivity;SyntheticProviderService SyntheticAssertionActivity FakeLockApi..', 'AndroidManifest.xml': 'app.otpanda.fixture'.encode('utf-16le')})
rel = apk('release.apk', {'classes.dex': b'..Lapp/otpanda/MainActivity;LocalLockRecoveryHost..', 'AndroidManifest.xml': 'app.otpanda.MainActivity'.encode('utf-16le')})
leak = apk('leak.apk', {'classes2.dex': b'xx FakeLockApi xx'})
leak2 = apk('leak2.apk', {'AndroidManifest.xml': 'app.otpanda.fixture.LockPromptHostActivity'.encode('utf-16le')})
for n, args, code in (('release without fixture passes', [rel], 0), ('release with FakeLockApi in dex fails', [leak], 1), ('release with fixture in binary manifest fails', [leak2], 1),
                      ('debug apk is flagged as containing fixture', [dbg], 1), ('positive control finds all on debug', ['--expect-present', dbg], 0), ('positive control fails on release', ['--expect-present', rel], 1)):
    expect(n, subprocess.run([PY, f'{H}/check-release-artifact.py', *args], capture_output=True, text=True).returncode, code)
sys.exit(0 if ok else 1)
