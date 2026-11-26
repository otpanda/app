#!/usr/bin/env python3
"""Positive and negative tests for verify-log.py with synthetic logs (no device). Not OS evidence."""
import os, subprocess, sys, tempfile
V = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'verify-log.py')
GMS = 'com.google.android.gms/com.google.android.gms.auth.api.credentials.credentialmanager.CredentialActivity'
CM = 'com.android.credentialmanager/com.android.credentialmanager.CredentialSelectorActivity'
SC = [('observe_idle', 0), ('observe_home', 0), ('mimic_idle', 1), ('mimic_back', 1), ('mimic_home', 1)]
def ev(e, s, m, **k): return f'I LOCKFX : ev={e} t=0 scenario={s} mimic={m} pid=1 ' + ' '.join(f'{a}={b}' for a, b in k.items())
def mk(s, n, **k): return f'I LOCKFX : ev=mark scenario={s} name={n} ' + ' '.join(f'{a}={b}' for a, b in k.items())
OUTS = {'observe_idle': 'USER_CANCELLED', 'mimic_back': 'USER_CANCELLED', 'mimic_home': 'ABORTED'}
def scen(s, m, focus=CM, outcome=True, mark=True, early=None, extra_stop=False):
    L = [f'== scenario {s}', mk(s, 'BEGIN'), ev('onCreate', s, m), ev('attempt_start', s, m), ev('prompt_requested', s, m)]
    if early: L.append(ev(*early[:1], s, m, **early[1]))
    L += [mk(s, 'FOCUS_IDLE', value=focus), mk(s, 'SHOT_OK', file='a.png')]
    if extra_stop: L.append(ev('onStop', s, m))
    if s.endswith('home'):
        if mark: L.append(mk(s, 'HOME'))
        L.append(ev('onStop', s, m))
    if s.endswith('back') or s == 'observe_idle': L.append(mk(s, 'BACK'))
    if outcome and s in OUTS: L.append(ev('outcome', s, m, value=OUTS[s]))
    return L
def build(**over):
    L = ['API=34']
    for s, m in SC: L += scen(s, m, **over.get(s, {}))
    return L
def run(lines, env=None):
    f = tempfile.NamedTemporaryFile('w', suffix='.log', delete=False); f.write('\n'.join(lines) + '\n'); f.close()
    r = subprocess.run([sys.executable, V, f.name, '34'], capture_output=True, text=True, env={**os.environ, **(env or {})})
    os.unlink(f.name); return r.returncode, r.stdout
ok = True
def expect(name, code, lines, env=None, want=None):
    global ok
    c, out = run(lines, env); good = c == code and (want is None or want in out)
    print(('ok  ' if good else 'BAD ') + name); ok &= good
expect('complete log passes', 0, build(), want='SCOPE')
expect('gms credential activity passes', 0, build(observe_idle={'focus': GMS}))
expect('wrong API fails', 1, ['API=33'] + build()[1:])
expect('missing scenario fails', 1, [l for l in build() if 'mimic_back' not in l])
expect('no prompt_requested fails', 1, [l for l in build() if 'ev=prompt_requested t=0 scenario=observe_idle' not in l])
expect('crash fails', 1, build() + ['CRASH=yes'])
for name, f in (('app focus', 'app.otpanda/app.otpanda.fixture.LockPromptFixtureActivity'), ('keyguard', 'com.android.systemui/Keyguard'),
                ('launcher', 'com.google.android.apps.nexuslauncher/.NexusLauncherActivity'), ('ANR dialog', 'Application_Not_Responding__app.otpanda'),
                ('gms non-credential activity', 'com.google.android.gms/com.google.android.gms.update.Foo')):
    expect(f'{name} focus is not a prompt', 1, build(mimic_idle={'focus': f}), want='not a credential provider')
expect('missing screenshot fails', 1, [l for l in build() if not ('SHOT_OK' in l and 'observe_idle' in l)])
expect('early prompt_error before idle fails', 1, build(mimic_idle={'early': ('prompt_error', {'class': 'NoCredentialException'})}), want='before the idle check')
expect('early outcome before idle fails', 1, build(mimic_back={'early': ('outcome', {'value': 'PASSKEY_UNAVAILABLE'})}), want='before the idle check')
bb = build(); bb.insert(bb.index('== scenario mimic_idle') + 7, ev('outcome', 'mimic_idle', 1, value='ABORTED'))
expect('mimic_idle must stay pending', 1, bb, want='must stay pending')
expect('prompt-caused stop is a reported fact by default', 0, build(mimic_idle={'extra_stop': True}), want='self_stop_before_any_user_action=YES')
expect('prompt-caused stop fails with REQUIRE_NO_SELF_STOP=1', 1, build(mimic_idle={'extra_stop': True}), env={'REQUIRE_NO_SELF_STOP': '1'})
expect('mimic_back without outcome fails', 1, build(mimic_back={'outcome': False}), want='USER_CANCELLED')
expect('mimic_home without ABORTED fails', 1, build(mimic_home={'outcome': False}), want='ABORTED')
bb = build(); bb.insert(bb.index(ev('outcome', 'mimic_back', 1, value='USER_CANCELLED')), ev('outcome', 'mimic_back', 1, value='ABORTED'))
expect('two outcomes fail', 1, bb)
expect('HOME scenario without HOME mark fails', 1, build(mimic_home={'mark': False}), want='no HOME mark')
expect('observe_home without HOME mark fails', 1, build(observe_home={'mark': False}), want='no HOME mark')
sys.exit(0 if ok else 1)
