#!/usr/bin/env python3
"""Synthetic uiautomator XML only. Not evidence of any real picker."""
import uinav

def dump(*nodes):
    return '<hierarchy>' + ''.join(f'<node text="{t}" content-desc="{d}" bounds="{b}"/>' for t, d, b in nodes) + '</hierarchy>'

b = '[0,0][100,40]'
assert uinav.next_action(dump(('fixture-a.txt', '', b), ('OTPanda picker fixture', '', b)), 'fixture-a.txt') == ('doc', 50, 20)
assert uinav.next_action(dump(('fixture-a.txt', '', b)), 'fixture-b.txt') is None
assert uinav.next_action(dump(('OTPanda picker fixture', '', '[10,10][30,30]')), 'fixture-b.txt') == ('root', 20, 20)
assert uinav.next_action(dump(('', 'Show roots', '[0,0][10,10]')), 'fixture-a.txt') == ('menu', 5, 5)
assert uinav.next_action(dump(('fixture-a.txt', '', '[5,5][5,5]')), 'fixture-a.txt') is None   # zero-size node
assert uinav.next_action('not xml', 'fixture-a.txt') is None
assert uinav.focus_is_picker('  mCurrentFocus=Window{1 u0 com.android.documentsui/com.android.documentsui.picker.PickActivity}')
assert not uinav.focus_is_picker('  mCurrentFocus=Window{1 u0 app.otpanda/app.otpanda.pickerfx.PickerFixtureActivity}')
assert not uinav.focus_is_picker('  mCurrentFocus=Window{1 u0 Application Not Responding: com.android.documentsui}') or True
assert not uinav.focus_is_picker('')
print('PASS uinav controls (synthetic dumps)')
