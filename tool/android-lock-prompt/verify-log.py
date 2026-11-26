#!/usr/bin/env python3
"""Fail-closed verifier for the lock-prompt runtime fixture log. Usage: verify-log.py fixture.log EXPECT_API
Exit 0 only when every scenario ran, a credential-provider window held focus before any user action, and the asserted outcomes match.
The prompt-caused self-stop is a FACT; it fails the run only when REQUIRE_NO_SELF_STOP=1 (set it in CI).
SCOPE (printed): synthetic allowCredentials id on an emulator -> the provider's no-passkey/error sheet at most. NOT a real credential selection or biometric path,
NOT FlutterActivity/MainActivity (plain Activity hosts the prompt), NOT real hardware."""
import os, re, sys
SCENARIOS = ['observe_idle', 'observe_home', 'mimic_idle', 'mimic_back', 'mimic_home']
EV = re.compile(r'ev=(\w+)(.*)')
SCOPE = 'synthetic-id provider sheet on emulator; not selection/biometric, not FlutterActivity/MainActivity, not hardware'
BAD_FOCUS = re.compile(r'not_responding|anr|keyguard|launcher|systemui|statusbar|notification|null|^app\.otpanda', re.I)
def provider_focus(v):
    """Only a credential provider window counts as the prompt. Anything else (app, launcher, keyguard, ANR dialog, SystemUI) does not."""
    if not v or BAD_FOCUS.search(v): return False
    pkg, _, act = v.partition('/')
    if pkg == 'com.android.credentialmanager': return True
    return pkg == 'com.google.android.gms' and re.search(r'credential|identity|fido|passkey', act, re.I) is not None
def kv(s): return dict(re.findall(r'(\w+)=(\S*)', s))
def parse(path):
    sc, cur = {}, None
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        m = re.match(r'== scenario (\w+)', line)
        if m: cur = m.group(1); sc[cur] = []; continue
        i = line.find('ev=')
        if cur is None or i < 0 or 'LOCKFX' not in line: continue
        m = EV.match(line[i:])
        if not m: continue
        d = kv(m.group(2)); d['ev'] = m.group(1)
        if d.get('scenario') == cur: sc[cur].append(d)
    return sc
def mark_idx(e, *names): return next((i for i, x in enumerate(e) if x['ev'] == 'mark' and x.get('name') in names), None)
def analyze(sc, require_no_self_stop=False):
    errs, facts = [], []
    for name in SCENARIOS:
        e = sc.get(name)
        if not e: errs.append(f'{name}: scenario missing'); continue
        evs = [x['ev'] for x in e]
        for need in ('onCreate', 'attempt_start', 'prompt_requested'):
            if need not in evs: errs.append(f'{name}: no {need} (harness or transport problem, not evidence)')
        if evs.count('onCreate') != 1: errs.append(f'{name}: onCreate count {evs.count("onCreate")}')
        idle = mark_idx(e, 'FOCUS_IDLE'); act = mark_idx(e, 'HOME', 'BACK'); want = name.endswith(('home', 'back'))
        if idle is None: errs.append(f'{name}: no idle focus evidence'); idle = len(e)
        focus = e[idle].get('value', '') if idle < len(e) else ''
        if idle < len(e):
            if not provider_focus(focus): errs.append(f'{name}: focus is not a credential provider window ({focus}); keyguard/ANR/launcher/app do not count')
            if not any(x['ev'] == 'mark' and x.get('name') == 'SHOT_OK' for x in e[idle:idle + 2]): errs.append(f'{name}: no screenshot evidence at idle')
            early = [x['ev'] for x in e[:idle] if x['ev'] in ('prompt_error', 'outcome', 'prompt_result')]
            if early: errs.append(f'{name}: {",".join(early)} before the idle check (prompt did not stay up)')
        if name.endswith(('home', 'back')) and act is None: errs.append(f'{name}: no user-action mark')
        if name.endswith('home') and mark_idx(e, 'HOME') is None: errs.append(f'{name}: no HOME mark')
        if name.endswith('back') and mark_idx(e, 'BACK') is None: errs.append(f'{name}: no BACK mark')
        outs = [x['value'] for x in e if x['ev'] == 'outcome']
        if len(outs) > 1: errs.append(f'{name}: outcome delivered {len(outs)} times (not exactly once)')
        stops = [i for i, x in enumerate(e) if x['ev'] == 'onStop']
        user_act = mark_idx(e, 'HOME', 'BACK')
        self_stop = any(user_act is None or i < user_act for i in stops)
        user_stop = user_act is not None and any(i > user_act for i in stops)
        if name == 'observe_idle' and outs != ['USER_CANCELLED']: errs.append(f'{name}: after BACK expected USER_CANCELLED once, got {outs}')
        if name == 'mimic_idle' and outs: errs.append(f'{name}: attempt must stay pending while the prompt is up, got outcome {outs}')
        if name == 'mimic_back' and outs != ['USER_CANCELLED']: errs.append(f'{name}: expected USER_CANCELLED once, got {outs}')
        if name == 'mimic_home':
            if outs != ['ABORTED']: errs.append(f'{name}: expected ABORTED once, got {outs}')
            if not user_stop: errs.append(f'{name}: HOME did not stop the activity')
        if name == 'observe_home' and not user_stop: errs.append(f'{name}: HOME did not stop the activity')
        if name == 'mimic_idle' and self_stop and require_no_self_stop: errs.append(f'{name}: prompt-caused onStop observed with REQUIRE_NO_SELF_STOP=1')
        pe = [x for x in e if x['ev'] == 'prompt_error']
        facts.append(f'{name}: provider_ui={"yes" if provider_focus(focus) else "NO"} focus={focus} self_stop_before_any_user_action={"YES" if self_stop else "no"} '
                     f'user_stop_after_mark={"yes" if user_stop else "no"} outcomes={outs or "none"} prompt_error={pe[0].get("class") if pe else "none"} '
                     f'sequence={",".join(x for x in evs if x != "focus")}')
    return errs, facts
def main():
    path, api = sys.argv[1], sys.argv[2]
    txt = open(path, errors='replace').read()
    errs = []
    if f'API={api}' not in txt: errs.append(f'API header missing or not {api}')
    if 'CRASH=yes' in txt: errs.append('crash or ANR in the crash buffer')
    e2, facts = analyze(parse(path), os.environ.get('REQUIRE_NO_SELF_STOP') == '1')
    errs += e2
    for f in facts: print('FACT', f)
    print('SCOPE', SCOPE)
    if errs:
        for e in errs: print('FAIL', e)
        sys.exit(1)
    print('PASS lock-prompt fixture, API', api + '; scope:', SCOPE)
if __name__ == '__main__': main()
