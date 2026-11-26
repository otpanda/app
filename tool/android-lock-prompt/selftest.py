#!/usr/bin/env python3
"""Positive and negative tests for verify-log.py using synthetic logs (no device). Not OS evidence."""
import os, subprocess, sys, tempfile
V = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'verify-log.py')
def line(ev, s, m, t=0, **k): return f'I LOCKFX : ev={ev} t={t} scenario={s} mimic={m} pid=1 ' + ' '.join(f'{a}={b}' for a, b in k.items())
def mk(s, name, **k): return f'I LOCKFX : ev=mark scenario={s} name={name} ' + ' '.join(f'{a}={b}' for a, b in k.items())
def scen(s, m, stops=(), idle=True, ui=True, extra=()):
    L = [f'== scenario {s}', mk(s, 'BEGIN'), line('onCreate', s, m), line('attempt_start', s, m), line('prompt_requested', s, m)]
    if idle:
        L += [mk(s, 'FOCUS_IDLE', value='com.google.android.gms/x' if ui else 'app.otpanda/app.otpanda.fixture.X'), mk(s, 'SHOT_OK', file='a.png')]
    if s.endswith('home'):
        L += [mk(s, 'HOME'), line('onStop', s, m)]
    L += [line('onStop', s, m)] * len(stops)
    return L + list(extra)
def build(mut=None):
    L = ['API=34']
    for s, m in (('observe_idle', 0), ('observe_home', 0), ('mimic_idle', 1), ('mimic_back', 1), ('mimic_home', 1)):
        L += scen(s, m, idle=s.endswith('idle'))
    return L
def run(lines, env=None):
    f = tempfile.NamedTemporaryFile('w', suffix='.log', delete=False); f.write('\n'.join(lines) + '\n'); f.close()
    r = subprocess.run([sys.executable, V, f.name, '34'], capture_output=True, text=True, env={**os.environ, **(env or {})})
    os.unlink(f.name); return r.returncode, r.stdout
ok = True
def expect(name, code, lines, env=None, want=None):
    global ok
    c, out = run(lines, env)
    good = c == code and (want is None or want in out)
    print(('ok  ' if good else 'BAD ') + name); ok &= good
expect('complete log passes', 0, build())
expect('wrong API fails', 1, ['API=33'] + build()[1:])
expect('missing scenario fails', 1, [l for l in build() if 'mimic_back' not in l])
expect('no prompt_requested fails', 1, [l for l in build() if 'ev=prompt_requested t=0 scenario=observe_idle' not in l])
expect('crash fails', 1, build() + ['CRASH=yes'])
b = build(); i = b.index('== scenario mimic_idle'); b[i+1:i+1] = []
b2 = [l.replace('app.otpanda/', 'app.otpanda/') for l in build()]
expect('no system UI and no stop is inconclusive', 1, [l.replace('com.google.android.gms/x', 'app.otpanda/y') if 'observe_idle' in l else l for l in build()], want='no system prompt UI')
expect('missing screenshot fails', 1, [l for l in build() if not ('SHOT_OK' in l and 'observe_idle' in l)])
bb = build(); j = bb.index('== scenario mimic_idle') + 1
bb.insert(j + 4, line('onStop', 'mimic_idle', 1))
expect('prompt-caused stop is reported, not failed by default', 0, bb, want='self_stop_before_any_user_action=YES')
expect('prompt-caused stop fails when required absent', 1, bb, env={'REQUIRE_NO_SELF_STOP': '1'})
bb = build(); j = bb.index('== scenario mimic_back') + 1
bb[j:j] = [line('outcome', 'mimic_back', 1, value='ABORTED')] * 2
expect('double outcome fails', 1, bb)
bb = build(); k = [l for l in bb if not (l.startswith('I LOCKFX') and 'name=HOME' in l and 'observe_home' in l)]
expect('home scenario without HOME mark does not count as user stop (self stop)', 0, k, want='observe_home')
sys.exit(0 if ok else 1)
