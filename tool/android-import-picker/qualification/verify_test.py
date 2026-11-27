#!/usr/bin/env python3
"""Verifier controls with synthetic logs, not Android evidence."""
import subprocess, sys, tempfile
from pathlib import Path

v = Path(__file__).with_name('verify.py')
L = lambda *x: '\n'.join(x)
CHK = lambda label: f'CHECK {label} true'
SEL = lambda *d: '\n'.join(f'HARNESS selected {x}' for x in d)

def logs(name, checks, opens, extra=''):
    return L(*[CHK(c) for c in checks], *[f'OPEN {d} 1' for d in opens], extra)

FILES = {
    'normal': (logs('normal', ['normal_first_text', 'normal_backgrounded', 'normal_busy_pending', 'normal_second_text', 'normal_cancel_null', 'phase_complete'], ['a', 'b'], 'ACT stop 1'), SEL('a', 'b')),
    'errors': (logs('errors', ['errors_not_text', 'errors_too_large', 'phase_complete'], ['bad', 'big']), SEL('bad', 'big')),
    'rotation': (logs('rotation', ['rotation_text', 'phase_complete'], ['a']), SEL('a')),
    'recreate': (logs('recreate', ['rotation_recreated_dropped', 'phase_complete'], []), SEL('a')),
    'stale_recreate': (logs('s', ['stale_old_engine_gone', 'stale_second_text', 'phase_complete'], ['b'], 'ACT create 2 restored true\nENGINE cleanup 1\nENGINE configure 1\nENGINE configure 2'), SEL('a', 'b') + '\nHARNESS recreated_before_selection'),
    'stale_kill': (logs('s', ['stale_old_engine_gone', 'stale_second_text', 'phase_complete'], ['b'], 'ACT create 2 restored true\nENGINE configure 1\nENGINE configure 2'), SEL('a', 'b') + '\nHARNESS pid_before 100\nHARNESS pid_after_kill none\nHARNESS killed_before_selection\nHARNESS pid_after_restore 200'),
}

def write(p, files):
    for n, (log, drive) in files.items():
        (p / f'{n}.log').write_text(log); (p / f'{n}-drive.txt').write_text(drive)
        (p / f'crash-{n}.txt').write_text(''); (p / f'ui-{n}-final.xml').write_text('<node text="Synthetic picker fixture check"/>')

def ok(p): return subprocess.run([sys.executable, str(v), str(p)], capture_output=True).returncode == 0

with tempfile.TemporaryDirectory() as t:
    p = Path(t)
    write(p, FILES); assert ok(p), 'baseline must pass'
    def mutate(n, fn=None, drive=None, extra_files=None):
        files = dict(FILES)
        log, d = files[n]
        files[n] = (fn(log) if fn else log, drive(d) if drive else d)
        write(p, files)
        return ok(p)
    for n, (log, d) in FILES.items():
        assert not mutate(n, lambda l: l + '\nCHECK phase_failed false'), f'{n}: failed check'
        assert not mutate(n, lambda l: l + '\nOPEN zzz 1'), f'{n}: unexpected provider open'
        assert not mutate(n, drive=lambda x: x + '\nHARNESS FAILED x'), f'{n}: harness failure'
        if 'selected a' in d:
            assert not mutate(n, drive=lambda x: x.replace('HARNESS selected a', '')), f'{n}: unselected'
        for label in [m.group(1) for m in __import__('re').finditer(r'CHECK (\w+) true', log)]:
            assert not mutate(n, lambda l: l.replace(f'CHECK {label} true', '')), f'{n}: missing {label}'
            assert not mutate(n, lambda l: l + f'\nCHECK {label} true'), f'{n}: duplicate {label}'
    # stale selection opened: the property this fixture exists to catch
    for n in ('stale_recreate', 'stale_kill'):
        assert not mutate(n, lambda l: l + '\nOPEN a 1'), f'{n}: stale selection opened must fail'
        assert not mutate(n, lambda l: l.replace('OPEN b 1', 'OPEN b 1\nOPEN b 2')), f'{n}: new selection opened twice must fail'
    assert not mutate('stale_kill', drive=lambda d: d.replace('pid_after_restore 200', 'pid_after_restore 100')), 'process must change'
    assert not mutate('stale_kill', drive=lambda d: d.replace('pid_after_kill none', 'pid_after_kill 100')), 'process must have died'
    assert not mutate('stale_kill', drive=lambda d: d.replace('HARNESS killed_before_selection', '')), 'death must precede the selection'
    assert not mutate('stale_recreate', drive=lambda d: d.replace('HARNESS recreated_before_selection', '')), 'retirement must precede the selection'
    assert not mutate('stale_recreate', lambda l: l.replace('ENGINE cleanup 1', '')), 'engine cleanup must be observed'
    # ordinary lifecycle telemetry is not a failed check, a real false check is
    assert mutate('normal', lambda l: l + '\nACT create 1 restored false'), 'restored false telemetry must pass'
    assert not mutate('normal', lambda l: l + '\nCHECK something false'), 'a false check must fail'
    assert not mutate('stale_recreate', lambda l: l.replace('ACT create 2 restored true', '')), 'caller must be restored'
    assert not mutate('rotation', lambda l: l.replace('OPEN a 1', '')), 'delivered without being opened'
    assert not mutate('recreate', lambda l: l + '\nOPEN a 1'), 'dropped but opened'
    assert not mutate('normal', lambda l: l.replace('ACT stop 1', '')), 'never backgrounded'
    write(p, FILES); (p / 'crash-normal.txt').write_text('FATAL EXCEPTION'); assert not ok(p)
    write(p, FILES); (p / 'ui-normal-final.xml').write_text('<node text="x"/>'); assert not ok(p)
    write(p, FILES); (p / 'ui-normal-final.xml').write_text('<node text="Synthetic picker fixture check"/><node text="isn\'t responding"/>'); assert not ok(p)
print('PASS verifier negative controls (synthetic logs)')
