#!/usr/bin/env python3
"""Fail-closed verifier for the lock-prompt runtime fixture log. Usage: verify-log.py fixture.log EXPECT_API
Exit 0 only when every scenario ran and was conclusive. It REPORTS facts (self-stop yes/no) and only gates on them when
REQUIRE_NO_SELF_STOP=1. A harness problem (missing events, no prompt UI) is a failure, never a pass."""
import os, re, sys
SCENARIOS = ['observe_idle', 'observe_home', 'mimic_idle', 'mimic_back', 'mimic_home']
EV = re.compile(r'ev=(\w+)(.*)')
def kv(s): return dict(re.findall(r'(\w+)=(\S*)', s))
def parse(path):
    sc, cur = {}, None
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        m = re.match(r'== scenario (\w+)', line)
        if m: cur = m.group(1); sc[cur] = []; continue
        if cur is None: continue
        i = line.find('ev=')
        if i < 0 or 'LOCKFX' not in line: continue
        m = EV.match(line[i:])
        if not m: continue
        d = kv(m.group(2)); d['ev'] = m.group(1)
        if d['ev'] != 'mark' and d.get('scenario') != cur: continue
        if d['ev'] == 'mark' and d.get('scenario') != cur: continue
        sc[cur].append(d)
    return sc
def analyze(sc, api, require_no_self_stop=False):
    errs, facts = [], []
    hdr = [l for l in open(sys.argv[1], errors='replace') if l.startswith('API=')]
    for name in SCENARIOS:
        e = sc.get(name)
        if not e: errs.append(f'{name}: scenario missing'); continue
        evs = [x['ev'] for x in e]
        for need in ('onCreate', 'attempt_start', 'prompt_requested'):
            if need not in evs: errs.append(f'{name}: no {need} (harness or transport problem, not evidence)')
        if evs.count('onCreate') != 1: errs.append(f'{name}: onCreate count {evs.count("onCreate")}')
        if any(x['ev'] == 'mark' and x.get('name') == 'FOCUS_ERROR' for x in e): errs.append(f'{name}: focus dump failed')
        outcomes = [x['value'] for x in e if x['ev'] == 'outcome']
        if len(outcomes) > 1: errs.append(f'{name}: outcome delivered {len(outcomes)} times (not exactly once)')
        first_mark = next((i for i, x in enumerate(e) if x['ev'] == 'mark' and x.get('name') in ('HOME', 'BACK')), None)
        stops = [i for i, x in enumerate(e) if x['ev'] == 'onStop']
        self_stop = any(first_mark is None or i < first_mark for i in stops)
        user_stop = any(first_mark is not None and i > first_mark for i in stops)
        focus = next((x.get('value', '') for x in e if x['ev'] == 'mark' and x.get('name') == 'FOCUS_IDLE'), None)
        ui = bool(focus) and 'app.otpanda' not in focus.split('/')[0] and 'null' not in focus
        if name in ('observe_idle', 'mimic_idle') :
            if focus is None: errs.append(f'{name}: no idle focus evidence')
            elif not ui and not self_stop: errs.append(f'{name}: no system prompt UI observed (focus={focus}); inconclusive')
        shot = [x for x in e if x['ev'] == 'mark' and x.get('name') == 'SHOT_OK']
        if name in ('observe_idle', 'mimic_idle') and not shot: errs.append(f'{name}: no screenshot evidence')
        if name == 'observe_home' and 'onStop' not in evs: errs.append(f'{name}: HOME did not stop the activity')
        if name == 'mimic_home' and not user_stop: errs.append(f'{name}: HOME did not stop the activity')
        err_ev = [x for x in e if x['ev'] == 'prompt_error']
        facts.append(f'{name}: prompt_ui={"yes" if ui else "no"} focus={focus} self_stop_before_any_user_action={"YES" if self_stop else "no"} '
                     f'user_stop_after_mark={"yes" if user_stop else "no"} outcome={outcomes[0] if outcomes else "none"} '
                     f'prompt_error={err_ev[0].get("class") if err_ev else "none"} sequence={",".join(x for x in evs if x not in ("focus",))}')
        if require_no_self_stop and name == 'mimic_idle' and self_stop: errs.append(f'{name}: prompt-caused onStop observed with REQUIRE_NO_SELF_STOP=1')
    return errs, facts
def main():
    path, api = sys.argv[1], sys.argv[2]
    txt = open(path, errors='replace').read()
    errs = []
    if f'API={api}' not in txt: errs.append(f'API header missing or not {api}')
    if 'CRASH=yes' in txt: errs.append('crash buffer not empty')
    e2, facts = analyze(parse(path), api, os.environ.get('REQUIRE_NO_SELF_STOP') == '1')
    errs += e2
    for f in facts: print('FACT', f)
    if errs:
        for e in errs: print('FAIL', e)
        sys.exit(1)
    print('PASS lock-prompt fixture observed all scenarios (emulator OS prompt behavior on API', api + ', not real hardware evidence)')
if __name__ == '__main__': main()
