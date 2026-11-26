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
def scen(s, ready_enabled='true', after_enabled=None, focus=CM, entry='yes', outcome=True, home_mark=True, early_outcome=False, extra_stop=False, begin_ok='1', host='realHost=1', flag='true', selected=True, finish_ok='1', consume=('true', 'false'), flag_after=None, shot=True, provider_begin=True):
    L = [f'== scenario {s}', mk(s, 'BEGIN'), ev('onCreate', s), f'I LOCKFX : ev=host_ready t=0 scenario={s} pid=1 api=fake loopback=1 {host} flag={flag}', ev('attempt_start', s)]
    L.append(ev('app_lock_enabled', s, phase='ready', value=ready_enabled))
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
    if s.endswith('select') and outcome:
        want = 'true' if s == 'unlock_select' else 'false'
        L.append(ev('flag_after', s, present=flag_after or want)); L.append(ev('app_lock_enabled', s, phase='after', value=after_enabled or want))
    return L
DS = ['dart_unlock_idle', 'dart_back', 'dart_cancel', 'dart_home', 'dart_unlock_select', 'dart_disable_select']
DOUT = {'dart_back': 'USER_CANCELLED', 'dart_cancel': 'ABORTED', 'dart_home': 'ABORTED', 'dart_unlock_select': 'UNLOCK_GRANTED', 'dart_disable_select': 'DISABLED'}
def de(e, s, **k): return ev('dart_' + e, s, **k)
def dscen(s, host='api=fake loopback=0 realMessenger=1 realHost=1 flag=true', loaded=('true', 'true', 'true'), outcome=None, done=True, done_vals=None, focus=CM, entry='yes', early=False, busy=True,
          lifecycle=True, resumed=True, consume='true', flag_after=None, real_enabled=None, cancel_call=True, chan_cancel=True, home_stop=True, chan_start=1, selected=True, taps=0, extra_stop=False, ret=True):
    L = [f'== scenario {s}', mk(s, 'BEGIN'), ev('onCreate', s), f'I LOCKFX : ev=host_ready t=0 scenario={s} pid=1 {host}',
         de('loaded', s, ready=loaded[0], enabled=loaded[1], locked=loaded[2]), de('recover_start', s, disable='disable' in s)]
    for _ in range(chan_start): L.append(de('channel_start', s, intent='x'))
    L.append(ev('fake_begin', s, ok='1', intent='local-lock-disable' if 'disable' in s else 'local-unlock-once'))
    if busy: L.append(de('state', s, tag='listen', enabled='true', locked='true', busy='true', error='none'))
    L.append(pe('provider_begin_get', options=1))
    if early: L.append(de('outcome', s, value='ABORTED'))
    L += [mk(s, 'FOCUS_IDLE', value=focus), mk(s, 'ENTRY_VISIBLE', value=entry), mk(s, 'SHOT_OK', file='a.png')]
    if extra_stop: L.append(ev('onStop', s))
    if s == 'dart_back': L.append(mk(s, 'BACK'))
    if s == 'dart_cancel':
        if cancel_call: L.append(de('cancel_called', s))
        if chan_cancel: L.append(de('channel_cancel', s))
        L.append(mk(s, 'FOCUS_AFTER_CANCEL', value='com.android.credentialmanager/x'))
    if s == 'dart_home':
        L.append(mk(s, 'HOME'))
        if home_stop: L.append(ev('onStop', s))
        if lifecycle: L.append(de('lifecycle', s, state='paused'))
        if ret: L.append(mk(s, 'RETURN'))
        if resumed: L.append(de('lifecycle', s, state='resumed'))
    if s.endswith('select'):
        L.append(mk(s, 'TAP_ENTRY'))
        for _ in range(taps): L.append(mk(s, 'TAP_CONFIRM', xy='1,2'))
        if selected: L.append(pe('provider_selected'))
        L.append(ev('fake_finish', s, ok='1', challenge_match='1'))
    o = outcome if outcome is not None else DOUT.get(s)
    if o: L.append(de('outcome', s, value=o))
    if o and consume and s == 'dart_unlock_select': L.append(de('consume', s, value=consume))
    if done and s != 'dart_unlock_idle':
        en, lk = ('false', 'false') if s == 'dart_disable_select' else (('true', 'false') if s == 'dart_unlock_select' else ('true', 'true'))
        dv = dict(enabled=en, locked=lk, busy='false', error='none'); dv.update(done_vals or {})
        L.append(de('recover_done', s, **dv))
        if s.endswith('select'):
            want = 'false' if s == 'dart_disable_select' else 'true'
            L.append(de('app_lock_enabled', s, value=real_enabled or want)); L.append(ev('flag_after', s, present=flag_after or want))
    if s == 'dart_cancel':
        L = [l for l in L if 'name=FOCUS_AFTER_CANCEL' not in l] + [mk(s, 'FOCUS_AFTER_CANCEL', value=CM)]
    return L
def build(head=('API=34', 'ENABLE=OK'), tail=(), modes='loopback,dart', **over):
    L = list(head) + ([f'MODES={modes}'] if modes else [])
    if 'loopback' in modes:
        for s in SC: L += scen(s, **over.get(s, {}))
    if 'dart' in modes:
        for s in DS: L += dscen(s, **over.get(s, {}))
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
v('loopback-only log passes', build(modes='loopback'), 0)
v('dart-only log passes', build(modes='dart'), 0, 'Dart LocalLockController')
v('missing MODES header fails', build(modes=''), 1, 'MODES')
v('mode set but dart scenarios absent fails', [l for l in build() if 'dart_' not in l or l.startswith('MODES')], 1, 'scenario missing')
D = lambda **k: build(modes='dart', **k)
v('dart: host_ready loopback=1 fails', D(dart_back={'host': 'api=fake loopback=1 realMessenger=1 realHost=1 flag=true'}), 1, 'host_ready must show')
v('dart: not the real messenger fails', D(dart_back={'host': 'api=fake loopback=0 realMessenger=0 realHost=1 flag=true'}), 1, 'host_ready must show')
v('dart: controller not locked at load fails', D(dart_back={'loaded': ('true', 'true', 'false')}), 1, 'did not load')
v('dart: no loaded event fails', [l for l in D() if not ('ev=dart_loaded ' in l and 'scenario=dart_back ' in l)], 1, 'no dart_loaded')
v('dart cancel missing focus after completion fails', [l for l in D() if not ('scenario=dart_cancel ' in l and 'name=FOCUS_AFTER_CANCEL' in l)], 1, 'FOCUS_AFTER_CANCEL')
badfocus = D(); fi = next(i for i,l in enumerate(badfocus) if 'scenario=dart_cancel ' in l and 'name=FOCUS_AFTER_CANCEL' in l); item = badfocus.pop(fi); ci = next(i for i,l in enumerate(badfocus) if 'scenario=dart_cancel ' in l and 'ev=dart_channel_cancel ' in l); badfocus.insert(ci, item)
v('dart cancel focus sampled too soon fails', badfocus, 1, 'FOCUS_AFTER_CANCEL')
v('dart: channel start twice fails', D(dart_back={'chan_start': 2}), 1, 'exactly once')
v('dart: selector focus wrong fails', D(dart_back={'focus': 'com.android.systemui/Keyguard'}), 1, 'not a credential selector')
v('dart: entry not visible fails', D(dart_back={'entry': 'no'}), 1, 'not visible')
v('dart: early outcome fails', D(dart_back={'early': True}), 1, 'before the idle check')
v('dart_unlock_idle: outcome fails', D(dart_unlock_idle={'outcome': 'ABORTED'}), 1, 'must stay pending')
v('dart_unlock_idle: never busy fails', D(dart_unlock_idle={'busy': False}), 1, 'busy=true')
v('dart_back: wrong outcome fails', D(dart_back={'outcome': 'ABORTED'}), 1, 'USER_CANCELLED')
v('dart_back: error set fails', D(dart_back={'done_vals': {'error': 'set'}}), 1, 'recover_done')
v('dart_back: busy stuck fails', D(dart_back={'done_vals': {'busy': 'true'}}), 1, 'recover_done')
v('dart_back: controller unlocked fails', D(dart_back={'done_vals': {'locked': 'false'}}), 1, 'recover_done')
v('dart_back: no recover_done fails', D(dart_back={'done': False}), 1, 'recover_done')
v('dart_cancel: no cancel call fails', D(dart_cancel={'cancel_call': False}), 1, 'cancel was not issued')
v('dart_cancel: no channel cancel fails', D(dart_cancel={'chan_cancel': False}), 1, 'channel cancel')
v('dart_cancel: wrong outcome fails', D(dart_cancel={'outcome': 'USER_CANCELLED'}), 1, 'ABORTED')
v('dart_cancel: focus-after is a reported fact', D(), 0, 'focus_after_cancel=')
v('dart_home: Dart never paused fails', D(dart_home={'lifecycle': False}), 1, 'paused')
v('dart_home: Dart never resumed fails', D(dart_home={'resumed': False}), 1, 'resumed')
v('dart_home: no return mark fails', D(dart_home={'ret': False, 'resumed': False}), 1, 'RETURN')
v('dart_home: no activity stop fails', D(dart_home={'home_stop': False}), 1, 'did not stop')
v('dart_home: never completed fails', D(dart_home={'done': False}), 1, 'recover_done')
v('dart_select: not selected fails', D(dart_unlock_select={'selected': False}), 1, 'not selected')
v('dart_select: wrong outcome fails', D(dart_unlock_select={'outcome': 'ABORTED'}), 1, 'UNLOCK_GRANTED')
v('dart_select: consume false fails', D(dart_unlock_select={'consume': 'false'}), 1, 'consumeUnlock')
v('dart_select: consume missing fails', D(dart_unlock_select={'consume': None}), 1, 'consumeUnlock')
v('dart_select: controller still locked fails', D(dart_unlock_select={'done_vals': {'locked': 'true'}}), 1, 'recover_done')
v('dart_select: flag gone fails', D(dart_unlock_select={'flag_after': 'false'}), 1, 'flag present')
v('dart_select: real enabled() false fails', D(dart_unlock_select={'real_enabled': 'false'}), 1, 'enabled() must be')
v('dart_disable: flag still present fails', D(dart_disable_select={'flag_after': 'true'}), 1, 'flag present')
v('dart_disable: real enabled() true fails', D(dart_disable_select={'real_enabled': 'true'}), 1, 'enabled() must be')
v('dart_disable: controller still enabled fails', D(dart_disable_select={'done_vals': {'enabled': 'true'}}), 1, 'recover_done')
v('dart: two confirm taps fail', D(dart_unlock_select={'taps': 2}), 1, 'more than one confirm')
v('dart: self-stop is a fact', D(dart_unlock_idle={'extra_stop': True}), 0, 'self_stop_before_any_user_action=YES')
v('dart: self-stop fails when required', D(dart_unlock_idle={'extra_stop': True}), 1, 'REQUIRE_NO_SELF_STOP', env={'REQUIRE_NO_SELF_STOP': '1'})
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
v('disable with flag still present fails', build(disable_select={'flag_after': 'true'}), 1, 'lock flag present must be false')
v('disable with AppLockHost still enabled fails', build(disable_select={'after_enabled': 'true'}), 1, 'AppLockHost enabled must be false')
v('unlock with flag gone fails', build(unlock_select={'flag_after': 'false'}), 1, 'lock flag present must be true')
v('unlock with AppLockHost disabled fails', build(unlock_select={'after_enabled': 'false'}), 1, 'AppLockHost enabled must be true')
v('AppLockHost not enabled at ready fails', build(unlock_idle={'ready_enabled': 'false'}), 1, 'at host_ready')
bb = build(); i = bb.index(mk('unlock_select', 'TAP_ENTRY')); bb[i + 1:i + 1] = [mk('unlock_select', 'TAP_CONFIRM', xy='1,2'), mk('unlock_select', 'TAP_CONFIRM', xy='1,2')]
v('two confirm taps fail', bb, 1, 'more than one confirm')
bb = build(); bb.insert(bb.index(mk('unlock_select', 'TAP_ENTRY')), ev('onStop', 'unlock_select'))
v('self-stop before TAP_ENTRY is a fact', bb, 0, 'self_stop_before_any_user_action=YES')
v('self-stop before TAP_ENTRY fails when required', bb, 1, 'REQUIRE_NO_SELF_STOP', env={'REQUIRE_NO_SELF_STOP': '1'})
bb = build(); i = bb.index(ev('outcome', 'unlock_back', value='USER_CANCELLED')); bb.insert(i, ev('outcome', 'unlock_back', value='ABORTED'))
v('two outcomes fail', bb, 1)
# tap-entry
d = tempfile.mkdtemp(); x = f'{d}/u.xml'
open(x, 'w').write('<hierarchy><node text="Other" bounds="[0,0][10,10]"/><node text="synthetic-fixture-user" content-desc="" bounds="[100,200][300,260]"/></hierarchy>')
r = subprocess.run([PY, f'{H}/tap-entry.py', x, 'Synthetic fixture passkey', 'synthetic-fixture-user'], capture_output=True, text=True)
expect('tap-entry finds the center', (r.returncode, r.stdout.strip()), (0, '200 230'))
r = subprocess.run([PY, f'{H}/tap-entry.py', x, 'No such text'], capture_output=True, text=True); expect('tap-entry absent text exits 1', r.returncode, 1)
open(x, 'w').write('<hierarchy><node text="Continue" clickable="false" bounds="[0,0][10,10]"/><node text="Continue anyway later" clickable="true" bounds="[0,20][10,30]"/><node text="Sign in" clickable="true" bounds="[100,100][200,140]"/></hierarchy>')
r = subprocess.run([PY, f'{H}/tap-entry.py', '--exact-clickable', x, 'Continue'], capture_output=True, text=True); expect('exact-clickable ignores non-clickable and partial text', r.returncode, 1)
r = subprocess.run([PY, f'{H}/tap-entry.py', '--exact-clickable', x, 'Continue', 'Sign in'], capture_output=True, text=True); expect('exact-clickable finds Sign in', (r.returncode, r.stdout.strip()), (0, '150 120'))
open(x, 'w').write('<broken'); r = subprocess.run([PY, f'{H}/tap-entry.py', x, 'a'], capture_output=True, text=True); expect('tap-entry bad xml exits 1', r.returncode, 1)
# release artifact check
def apk(name, entries):
    p = f'{d}/{name}'
    with zipfile.ZipFile(p, 'w') as z:
        for n, b in entries.items(): z.writestr(n, b)
    return p
dbg = apk('debug.apk', {'classes.dex': b'..Lapp/otpanda/fixture/LockPromptHostActivity;SyntheticProviderService SyntheticAssertionActivity FakeLockApi..', 'AndroidManifest.xml': 'app.otpanda.fixture'.encode('utf-16le'), 'a.bin': b'lockfx/driver'})
rel = apk('release.apk', {'classes.dex': b'..Lapp/otpanda/MainActivity;LocalLockRecoveryHost..', 'AndroidManifest.xml': 'app.otpanda.MainActivity'.encode('utf-16le')})
leak = apk('leak.apk', {'classes2.dex': b'xx FakeLockApi xx'})
leak2 = apk('leak2.apk', {'AndroidManifest.xml': 'app.otpanda.fixture.LockPromptHostActivity'.encode('utf-16le')})
leak3 = apk('leak3.apk', {'classes.dex': b'x lockfx/driver x'})
for n, args, code in (('release with the driver channel name fails', [leak3], 1), ('release without fixture passes', [rel], 0), ('release with FakeLockApi in dex fails', [leak], 1), ('release with fixture in binary manifest fails', [leak2], 1),
                      ('debug apk is flagged as containing fixture', [dbg], 1), ('positive control finds all on debug', ['--expect-present', dbg], 0), ('positive control fails on release', ['--expect-present', rel], 1)):
    expect(n, subprocess.run([PY, f'{H}/check-release-artifact.py', *args], capture_output=True, text=True).returncode, code)
sys.exit(0 if ok else 1)
