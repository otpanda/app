#!/usr/bin/env python3
"""Judges the evidence drive.py collected. Every required label must appear exactly once, no check may be false, no crash, and
the synthetic provider's open counts must match: a stale selection must never be opened, a legitimate one exactly once."""
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
DONE = ['phase_complete']
REQUIRED = {
    'normal': ['normal_first_text', 'normal_backgrounded', 'normal_busy_pending', 'normal_second_text', 'normal_cancel_null'] + DONE,
    'errors': ['errors_not_text', 'errors_too_large'] + DONE,
    'stale_recreate': ['stale_old_engine_gone', 'stale_second_text'] + DONE,
    'stale_kill': ['stale_old_engine_gone', 'stale_second_text'] + DONE,
}
SELECTED = {
    'normal': ['a', 'b'], 'errors': ['bad', 'big'], 'rotation': ['a'], 'recreate': ['a'],
    'stale_recreate': ['a', 'b'], 'stale_kill': ['a', 'b'],
}
# Documents the provider must have opened, exactly once each. Anything else must have zero opens.
OPENS = {
    'normal': {'a': 1, 'b': 1}, 'errors': {'bad': 1, 'big': 1},
    'stale_recreate': {'b': 1}, 'stale_kill': {'b': 1},
}


def count(text, pattern):
    return len(re.findall(pattern, text, re.M))


def opens(text):
    got = {}
    for doc, n in re.findall(r'^.*PICKFX.*\bOPEN (\w+) (\d+)$', text, re.M) or re.findall(r'\bOPEN (\w+) (\d+)\s*$', text, re.M):
        got[doc] = got.get(doc, 0) + 1
    return got


def check_scenario(name):
    text = (p / f'{name}.log').read_text()
    drive = (p / f'{name}-drive.txt').read_text()
    assert 'HARNESS FAILED' not in drive and 'HARNESS EXCEPTION' not in drive, f'{name}: harness failure'
    assert ' false' not in text and 'fixture_exception' not in text, f'{name}: failed check'
    assert 'FATAL EXCEPTION' not in (p / f'crash-{name}.txt').read_text(), f'{name}: Android crash'
    ui = (p / f'ui-{name}-final.xml').read_text()
    assert 'Synthetic picker fixture check' in ui and not any(s in ui for s in ("isn't responding", 'is not responding')), f'{name}: fixture frame obscured or not ready'
    for doc in SELECTED[name]:
        assert f'HARNESS selected {doc}' in drive, f'{name}: the harness never selected {doc} in the real picker'
    if name in ('normal', 'errors', 'stale_recreate', 'stale_kill'):
        for label in REQUIRED[name]:
            assert count(text, rf'CHECK {label} true$') == 1, f'{name}: missing or duplicate {label}'
    got = opens(text)
    if name in OPENS:
        assert got == OPENS[name], f'{name}: provider opens {got}, expected {OPENS[name]}'
    if name in ('rotation', 'recreate'):
        used = count(text, r'CHECK rotation_text true$')
        dropped = count(text, r'CHECK rotation_recreated_dropped true$')
        assert used + dropped == 1 and count(text, r'CHECK phase_complete true$') == 1, f'{name}: need exactly one outcome'
        # engine survived: the one selection opened once and was delivered. Engine retired: it must never have been opened.
        assert got == ({'a': 1} if used else {}), f'{name}: provider opens {got} do not match the observed outcome'
    if name.startswith('stale'):
        assert count(text, r'ACT create \d+ restored true') >= 1, f'{name}: the caller was never restored by the system'
        assert count(text, r'ENGINE configure') >= 2, f'{name}: no second engine'
    if name == 'stale_kill':
        before = re.search(r'pid_before (\d+)', drive); after = re.search(r'pid_after_restore (\d+)', drive)
        assert before and after and before.group(1) != after.group(1), f'{name}: process did not change'
    if name == 'normal':
        assert count(text, r'ACT stop \d+') >= 1, f'{name}: the app was never backgrounded by the picker'
    return 'used' if name in ('rotation', 'recreate') and count(text, r'CHECK rotation_text true$') else 'ok'


outcomes = {n: check_scenario(n) for n in SELECTED}
print('PASS installed picker fixture:', ', '.join(f'{n}={o}' for n, o in outcomes.items()),
      '| real Flutter engine, production ImportPickerHost, real system picker, synthetic DocumentsProvider only;',
      'not proven: other pickers or providers, real cloud providers, hardware devices')
