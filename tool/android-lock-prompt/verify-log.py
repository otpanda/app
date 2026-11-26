#!/usr/bin/env python3
"""Fail-closed verifier for the lock-prompt runtime fixture log. Usage: verify-log.py fixture.log EXPECT_API
Exit 0 only when every scenario ran, the SYNTHETIC provider's own entry was on screen in a credential-selector window before any user action, and every asserted
outcome matches. A prompt-caused self-stop is a FACT; it fails only when REQUIRE_NO_SELF_STOP=1 (set it in CI).
SCOPE: the repo's real MainActivity lifecycle hooks + real LocalLockRecoveryHost + real Credential Manager + a fixture provider and fake begin/finish on an emulator.
NOT Google Password Manager, Samsung, biometrics, real server verification of the signature, or hardware."""
import os, re, sys
SCENARIOS = ['unlock_idle', 'unlock_back', 'unlock_home', 'unlock_select', 'disable_select']
DART = ['dart_unlock_idle', 'dart_back', 'dart_cancel', 'dart_home', 'dart_unlock_select', 'dart_disable_select']
EV = re.compile(r'ev=(\w+)(.*)')
SCOPE = ('actual native host and MainActivity hooks (real LocalLockRecoveryHost, AppLockHost, onStop/onDestroy) driven over an in-process LOOPBACK messenger, '
         'not the real Dart controller, engine messenger or Dart-side cancel; real Credential Manager with this fixture\'s own provider task, which differs from the real '
         'Google Password Manager or Samsung provider; fake begin/finish; emulator; not biometric, not server signature verification, not hardware')
BAD_FOCUS = re.compile(r'not_responding|anr|keyguard|launcher|systemui|statusbar|notification|null|^app\.otpanda', re.I)
USER = ('HOME', 'BACK', 'TAP_ENTRY')
def provider_focus(v):
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
        if d.get('scenario') in (None, cur): sc[cur].append(d)   # provider events carry no scenario; the log is cleared per scenario
    return sc
def idx(e, name): return next((i for i, x in enumerate(e) if x['ev'] == name), None)
def mark(e, *names): return next((i for i, x in enumerate(e) if x['ev'] == 'mark' and x.get('name') in names), None)
def vals(e, ev, key): return [x.get(key) for x in e if x['ev'] == ev]
def analyze(sc, require_no_self_stop=False, modes=('loopback',)):
    errs, facts = [], []
    if 'dart' in modes:
        e2, f2 = analyze_dart(sc, require_no_self_stop); errs += e2; facts += f2
    for name in (SCENARIOS if 'loopback' in modes else []):
        e = sc.get(name)
        if not e: errs.append(f'{name}: scenario missing'); continue
        evs = [x['ev'] for x in e]
        for need in ('onCreate', 'host_ready', 'attempt_start', 'provider_begin_get'):
            if need not in evs: errs.append(f'{name}: no {need} (harness or provider problem, not evidence)')
        hr = next((x for x in e if x['ev'] == 'host_ready'), {})
        if hr and (hr.get('realHost') != '1' or hr.get('api') != 'fake'): errs.append(f'{name}: host_ready not realHost=1 api=fake')
        if hr and hr.get('flag') != 'true': errs.append(f'{name}: lock flag not present at host_ready')
        want_intent = 'local-lock-disable' if name.startswith('disable') else 'local-unlock-once'
        if 'ok=1' not in [f'ok={v}' for v in vals(e, 'fake_begin', 'ok')] or want_intent not in vals(e, 'fake_begin', 'intent'): errs.append(f'{name}: fake begin for {want_intent} not served')
        idle = mark(e, 'FOCUS_IDLE')
        if idle is None: errs.append(f'{name}: no idle focus evidence'); idle = len(e)
        focus = e[idle].get('value', '') if idle < len(e) else ''
        if idle < len(e):
            if not provider_focus(focus): errs.append(f'{name}: focus is not a credential selector window ({focus}); keyguard/ANR/launcher/app do not count')
            pb = idx(e, 'provider_begin_get')
            if pb is not None and pb > idle: errs.append(f'{name}: provider_begin_get after the idle check')
            if not any(x['ev'] == 'mark' and x.get('name') == 'ENTRY_VISIBLE' and x.get('value') == 'yes' for x in e): errs.append(f'{name}: the synthetic provider entry was not visible on screen (error sheet or other provider does not count)')
            if not any(x['ev'] == 'mark' and x.get('name') == 'SHOT_OK' for x in e): errs.append(f'{name}: no screenshot evidence at idle')
            early = [x['ev'] for x in e[:idle] if x['ev'] == 'outcome']
            if early: errs.append(f'{name}: outcome before the idle check (prompt did not stay up)')
        if sum(1 for x in e if x['ev'] == 'mark' and x.get('name') == 'TAP_CONFIRM') > 1: errs.append(f'{name}: more than one confirm tap')
        ar = [x for x in e if x['ev'] == 'app_lock_enabled' and x.get('phase') == 'ready']
        if len(ar) != 1 or ar[0].get('value') != 'true': errs.append(f'{name}: real AppLockHost did not report enabled=true at host_ready')
        user = mark(e, *USER)
        outs = vals(e, 'outcome', 'value')
        if len(outs) > 1: errs.append(f'{name}: outcome delivered {len(outs)} times (not exactly once)')
        stops = [i for i, x in enumerate(e) if x['ev'] == 'onStop']
        self_stop = any(user is None or i < user for i in stops)
        user_stop = user is not None and any(i > user for i in stops)
        if self_stop and require_no_self_stop: errs.append(f'{name}: onStop before any user action (prompt-caused self-stop) with REQUIRE_NO_SELF_STOP=1')
        if name == 'unlock_idle':
            if outs: errs.append(f'{name}: attempt must stay pending while the prompt is up, got {outs}')
        if name == 'unlock_back':
            if mark(e, 'BACK') is None: errs.append(f'{name}: no BACK mark')
            if outs != ['USER_CANCELLED']: errs.append(f'{name}: expected USER_CANCELLED once, got {outs}')
        if name == 'unlock_home':
            if mark(e, 'HOME') is None: errs.append(f'{name}: no HOME mark')
            if outs != ['ABORTED']: errs.append(f'{name}: expected ABORTED once, got {outs}')
            if not user_stop: errs.append(f'{name}: HOME did not stop the activity')
        if name in ('unlock_select', 'disable_select'):
            if mark(e, 'TAP_ENTRY') is None: errs.append(f'{name}: no TAP_ENTRY mark')
            if 'provider_selected' not in evs: errs.append(f'{name}: the synthetic provider entry was not selected')
            ff = [x for x in e if x['ev'] == 'fake_finish']
            if not ff or any(x.get('ok') != '1' or x.get('challenge_match') != '1' for x in ff): errs.append(f'{name}: fake finish not served with a matching challenge')
            exp = 'UNLOCK_GRANTED' if name == 'unlock_select' else 'DISABLED'
            if outs != [exp]: errs.append(f'{name}: expected {exp} once, got {outs}')
        if name in ('unlock_select', 'disable_select'):
            want = 'true' if name == 'unlock_select' else 'false'
            fa = [x for x in e if x['ev'] == 'flag_after']; aa = [x for x in e if x['ev'] == 'app_lock_enabled' and x.get('phase') == 'after']
            if len(fa) != 1 or fa[0].get('present') != want: errs.append(f'{name}: lock flag present must be {want} after the outcome (actual read)')
            if len(aa) != 1 or aa[0].get('value') != want: errs.append(f'{name}: real AppLockHost enabled must be {want} after the outcome (actual read)')
        if name == 'unlock_select':
            c = [x for x in e if x['ev'] == 'consume_unlock']
            if len(c) != 1 or c[0].get('first') != 'true' or c[0].get('second') != 'false': errs.append(f'{name}: consumeUnlock must be true once then false')
        facts.append(f'{name}: selector_focus={"yes" if provider_focus(focus) else "NO"} focus={focus} self_stop_before_any_user_action={"YES" if self_stop else "no"} '
                     f'user_stop_after_mark={"yes" if user_stop else "no"} outcomes={outs or "none"} sequence={",".join(x for x in evs if x != "focus")}')
    return errs, facts

DART_SCOPE = ('REAL Dart LocalLockController + NativeLocalLockRecovery + ChannelLocalRecovery/ChannelLocalLock over the REAL engine MethodChannels into the actual native hosts '
              '(real LocalLockRecoveryHost with a FAKE api, real AppLockHost, real MainActivity lifecycle); fixture Dart entry, placeholder bearer, no lock-screen button tap, '
              'no NativeRoot/session wiring; fixture provider, not Google or Samsung; fake begin/finish; emulator; not biometric, not server signature verification, not hardware')
def analyze_dart(sc, require_no_self_stop):
    errs, facts = [], []
    for name in DART:
        e = sc.get(name)
        if not e: errs.append(f'{name}: scenario missing'); continue
        evs = [x['ev'] for x in e]
        for need in ('onCreate', 'host_ready', 'dart_loaded', 'dart_recover_start', 'provider_begin_get', 'fake_begin'):
            if need not in evs: errs.append(f'{name}: no {need} (harness, Dart or provider problem, not evidence)')
        hr = next((x for x in e if x['ev'] == 'host_ready'), {})
        if hr and (hr.get('realHost') != '1' or hr.get('realMessenger') != '1' or hr.get('api') != 'fake' or hr.get('loopback') != '0' or hr.get('flag') != 'true'):
            errs.append(f'{name}: host_ready must show api=fake loopback=0 realMessenger=1 realHost=1 flag=true')
        ld = next((x for x in e if x['ev'] == 'dart_loaded'), {})
        if ld and (ld.get('ready') != 'true' or ld.get('enabled') != 'true' or ld.get('locked') != 'true'): errs.append(f'{name}: Dart controller did not load enabled=true locked=true (real AppLockHost read over the real channel)')
        want_intent = 'local-lock-disable' if 'disable' in name else 'local-unlock-once'
        if want_intent not in vals(e, 'fake_begin', 'intent') or 'ok=1' not in [f'ok={v}' for v in vals(e, 'fake_begin', 'ok')]: errs.append(f'{name}: fake begin for {want_intent} not served')
        cs = [x for x in e if x['ev'] == 'dart_channel_start']
        if len(cs) != 1: errs.append(f'{name}: Dart did not call the real recovery channel start exactly once')
        idle = mark(e, 'FOCUS_IDLE')
        if idle is None: errs.append(f'{name}: no idle focus evidence'); idle = len(e)
        focus = e[idle].get('value', '') if idle < len(e) else ''
        if idle < len(e):
            if not provider_focus(focus): errs.append(f'{name}: focus is not a credential selector window ({focus})')
            pb = idx(e, 'provider_begin_get')
            if pb is not None and pb > idle: errs.append(f'{name}: provider_begin_get after the idle check')
            if not any(x['ev'] == 'mark' and x.get('name') == 'ENTRY_VISIBLE' and x.get('value') == 'yes' for x in e): errs.append(f'{name}: the synthetic provider entry was not visible on screen')
            if not any(x['ev'] == 'mark' and x.get('name') == 'SHOT_OK' for x in e): errs.append(f'{name}: no screenshot evidence at idle')
            if any(x['ev'] in ('dart_outcome', 'dart_recover_done') for x in e[:idle]): errs.append(f'{name}: Dart outcome before the idle check (prompt did not stay up)')
        if sum(1 for x in e if x['ev'] == 'mark' and x.get('name') == 'TAP_CONFIRM') > 1: errs.append(f'{name}: more than one confirm tap')
        outs = vals(e, 'dart_outcome', 'value')
        if len(outs) > 1: errs.append(f'{name}: Dart outcome delivered {len(outs)} times')
        done = [x for x in e if x['ev'] == 'dart_recover_done']
        def done_is(en, lk):
            return len(done) == 1 and done[0].get('enabled') == en and done[0].get('locked') == lk and done[0].get('busy') == 'false' and done[0].get('error') == 'none'
        user = mark(e, 'HOME', 'BACK', 'TAP_ENTRY')
        stops = [i for i, x in enumerate(e) if x['ev'] == 'onStop']
        self_stop = any(user is None or i < user for i in stops)
        if self_stop and require_no_self_stop: errs.append(f'{name}: onStop before any user action (prompt-caused self-stop) with REQUIRE_NO_SELF_STOP=1')
        if name == 'dart_unlock_idle':
            if outs or done: errs.append(f'{name}: Dart attempt must stay pending while the prompt is up, got {outs}')
            if 'true' not in vals(e, 'dart_state', 'busy'): errs.append(f'{name}: Dart controller never reported busy=true')
        if name == 'dart_back':
            if mark(e, 'BACK') is None: errs.append(f'{name}: no BACK mark')
            if outs != ['USER_CANCELLED'] or not done_is('true', 'true'): errs.append(f'{name}: expected USER_CANCELLED once and recover_done enabled=true locked=true busy=false error=none, got {outs} {done}')
        if name == 'dart_cancel':
            ci = idx(e, 'dart_cancel_called')
            if ci is None: errs.append(f'{name}: Dart sessionChanged cancel was not issued')
            elif ci < idle: errs.append(f'{name}: cancel was issued before the idle check')
            if 'dart_channel_cancel' not in evs: errs.append(f'{name}: the real channel cancel was not called')
            fi = mark(e, 'FOCUS_AFTER_CANCEL')
            channel_cancel = idx(e, 'dart_channel_cancel')
            outcome_at = idx(e, 'dart_outcome')
            if fi is None or channel_cancel is None or outcome_at is None or fi <= max(channel_cancel, outcome_at):
                errs.append(f'{name}: FOCUS_AFTER_CANCEL must follow channel cancel and outcome')
            if outs != ['ABORTED'] or not done_is('true', 'true'): errs.append(f'{name}: expected ABORTED once and recover_done enabled=true locked=true busy=false error=none, got {outs} {done}')
        if name == 'dart_home':
            hm, rm = mark(e, 'HOME'), mark(e, 'RETURN')
            if hm is None: errs.append(f'{name}: no HOME mark')
            if rm is None: errs.append(f'{name}: no RETURN mark')
            if hm is not None and not any(i > hm for i in stops): errs.append(f'{name}: HOME did not stop the activity')
            if hm is not None and not any(x['ev'] == 'dart_lifecycle' and x.get('state') == 'paused' and i > hm for i, x in enumerate(e)): errs.append(f'{name}: Dart never saw lifecycle paused after HOME')
            if rm is not None and not any(x['ev'] == 'dart_lifecycle' and x.get('state') == 'resumed' and i > rm for i, x in enumerate(e)): errs.append(f'{name}: Dart never saw lifecycle resumed after RETURN')
            if not done_is('true', 'true'): errs.append(f'{name}: expected recover_done enabled=true locked=true busy=false error=none, got {done}')
            for k in ('RETURN_FOCUS', 'FOCUS_AFTER_RESUME', 'BACK_AFTER_RETURN'):
                fv = [x.get('value', 'yes') for x in e if x['ev'] == 'mark' and x.get('name') == k]
                if fv: facts.append(f'{name}: {k.lower()}={fv[0]} (reported fact)')
            if len(outs) != 1: errs.append(f'{name}: expected exactly one Dart outcome (value is a reported fact), got {outs}')
        if name in ('dart_unlock_select', 'dart_disable_select'):
            sel = name == 'dart_unlock_select'
            if mark(e, 'TAP_ENTRY') is None: errs.append(f'{name}: no TAP_ENTRY mark')
            if 'provider_selected' not in evs: errs.append(f'{name}: the synthetic provider entry was not selected')
            ff = [x for x in e if x['ev'] == 'fake_finish']
            if not ff or any(x.get('ok') != '1' or x.get('challenge_match') != '1' for x in ff): errs.append(f'{name}: fake finish not served with a matching challenge')
            exp = 'UNLOCK_GRANTED' if sel else 'DISABLED'
            if outs != [exp]: errs.append(f'{name}: expected {exp} once, got {outs}')
            # An unlock grant earned while the app is inactive is applied when the app resumes, so recover_done may still say locked=true. The gate is the settled checkpoint after resume.
            if sel:
                if not (len(done) == 1 and done[0].get('enabled') == 'true' and done[0].get('busy') == 'false' and done[0].get('error') == 'none'): errs.append(f'{name}: recover_done must be enabled=true busy=false error=none, got {done}')
            elif not done_is('false', 'false'): errs.append(f'{name}: recover_done must be enabled=false locked=false busy=false error=none, got {done}')
            want = 'true' if sel else 'false'
            fa = [x for x in e if x['ev'] == 'flag_after']; aa = vals(e, 'dart_app_lock_enabled', 'value')
            if len(fa) != 1 or fa[0].get('present') != want: errs.append(f'{name}: lock flag present must be {want} after the outcome (actual native read)')
            if aa != [want]: errs.append(f'{name}: real ChannelLocalLock.enabled() must be {want} after the outcome, got {aa}')
        if name in ('dart_home', 'dart_unlock_select', 'dart_disable_select'):
            st = [x for x in e if x['ev'] == 'dart_settled']
            want = {'dart_home': ('true', 'true'), 'dart_unlock_select': ('true', 'false'), 'dart_disable_select': ('false', 'false')}[name]
            if len(st) != 1: errs.append(f'{name}: no single dart_settled checkpoint')
            else:
                g = st[0]
                if g.get('resumed') != 'true': errs.append(f'{name}: app never resumed before the settled checkpoint')
                if (g.get('enabled'), g.get('locked')) != want or g.get('busy') != 'false' or g.get('error') != 'none': errs.append(f'{name}: settled state must be enabled={want[0]} locked={want[1]} busy=false error=none, got {g}')
                ri = idx(e, 'dart_settled'); rs = [i for i, x in enumerate(e) if x['ev'] == 'dart_lifecycle' and x.get('state') == 'resumed']
                after = mark(e, 'RETURN') if name == 'dart_home' else mark(e, 'TAP_ENTRY')
                if not any(i > (after or 0) and i < ri for i in rs): errs.append(f'{name}: no lifecycle resumed between the user action and the settled checkpoint')
        if sel_c(name):
            if vals(e, 'dart_consume', 'value') != ['true']: errs.append(f'{name}: consumeUnlock via the real channel must return true once')
        facts.append(f'{name}: selector_focus={"yes" if provider_focus(focus) else "NO"} focus={focus} self_stop_before_any_user_action={"YES" if self_stop else "no"} outcomes={outs or "none"} '
                     f'lifecycle={",".join(vals(e, "dart_lifecycle", "state")) or "none"} sequence={",".join(x for x in evs if x not in ("focus", "dart_state", "dart_lifecycle"))}')
        fc = [x.get('value') for x in e if x['ev'] == 'mark' and x.get('name') == 'FOCUS_AFTER_CANCEL']
        if fc: facts.append(f'{name}: focus_after_cancel={fc[0]} (reported fact, not gated)')
    return errs, facts
def sel_c(name): return name == 'dart_unlock_select'
def main():
    path, api = sys.argv[1], sys.argv[2]
    txt = open(path, errors='replace').read()
    errs = []
    if f'API={api}' not in txt: errs.append(f'API header missing or not {api}')
    if 'ENABLE=OK' not in txt: errs.append('provider enablement readback missing (ENABLE=OK)')
    if 'PROVIDER_REJECTED=yes' in txt: errs.append('the synthetic provider was rejected by the framework (harness failure)')
    if 'CRASH=yes' in txt: errs.append('crash or ANR in the crash buffer')
    mm = re.search(r'^MODES=(\S+)', txt, re.M)
    modes = tuple(mm.group(1).split(',')) if mm else ()
    if not modes or any(m not in ('loopback', 'dart') for m in modes): errs.append('MODES header missing or unknown'); modes = ()
    e2, facts = analyze(parse(path), os.environ.get('REQUIRE_NO_SELF_STOP') == '1', modes)
    errs += e2
    for f in facts: print('FACT', f)
    print('SCOPE', SCOPE if 'loopback' in modes else '', DART_SCOPE if 'dart' in modes else '')
    if errs:
        for e in errs: print('FAIL', e)
        sys.exit(1)
    print('PASS lock-prompt fixture, API', api, 'modes', ','.join(modes), '; scope:', SCOPE if 'loopback' in modes else '', DART_SCOPE if 'dart' in modes else '')
if __name__ == '__main__': main()
