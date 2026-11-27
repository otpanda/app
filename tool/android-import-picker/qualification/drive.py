#!/usr/bin/env python3
"""Drives the installed picker fixture on a disposable emulator through the REAL system document picker.
Usage: drive.py OUT_DIR. Needs adb, an emulator with the debug fixture APK installed. Not runnable without a device.
Writes per scenario: <s>.log (PICKFX logcat), <s>-drive.txt (HARNESS lines), ui/screenshot/crash files. verify.py judges them."""
import pathlib, re, subprocess, sys, time
import uinav

PKG = 'app.otpanda'
ACT = PKG + '/app.otpanda.pickerfx.PickerFixtureActivity'
SCENARIOS = ['normal', 'errors', 'rotation', 'recreate', 'stale_recreate', 'stale_kill']


class Harness(Exception):
    pass


def adb(*args, timeout=60, binary=False):
    r = subprocess.run(['adb', *args], capture_output=True, timeout=timeout)
    return r.stdout if binary else r.stdout.decode('utf-8', 'replace')


def shell(cmd, timeout=60):
    return adb('shell', cmd, timeout=timeout)


def logcat():
    return adb('logcat', '-d', '-s', 'PICKFX:I', '*:S')


def pid():
    return shell(f'pidof {PKG}').strip()


class Run:
    def __init__(self, out, name):
        self.out, self.name = pathlib.Path(out), name
        self.drive = open(self.out / f'{name}-drive.txt', 'w')

    def note(self, text):
        self.drive.write(text + '\n'); self.drive.flush()

    def wait_for(self, pattern, timeout=60, what=None):
        end = time.time() + timeout
        while time.time() < end:
            text = logcat()
            if re.search(pattern, text):
                return text
            if re.search(r'CHECK \S+ false', text):
                raise Harness(f'{self.name}: a fixture check failed while waiting for {what or pattern}')
            time.sleep(1)
        raise Harness(f'{self.name}: timed out waiting for {what or pattern}')

    def picker_focused(self, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            if uinav.focus_is_picker(shell('dumpsys window')):
                return
            time.sleep(1)
        raise Harness(f'{self.name}: the system document picker never took focus')

    def dump(self, tag):
        shell('uiautomator dump /sdcard/pickfx-ui.xml')
        xml = adb('exec-out', 'cat', '/sdcard/pickfx-ui.xml')
        (self.out / f'ui-{self.name}-{tag}.xml').write_text(xml)
        return xml

    def select(self, doc, label):
        """Navigate the real picker to the synthetic provider and tap the document. A document that never appears is a harness failure."""
        self.picker_focused()
        taps = {'root': 0, 'menu': 0}
        for _ in range(40):
            act = uinav.next_action(self.dump(f'select-{label}'), doc)
            if act:
                kind, x, y = act
                if kind in taps:
                    taps[kind] += 1
                    if taps[kind] > 4:
                        raise Harness(f'{self.name}: {kind} tap did not progress toward {label}')
                shell(f'input tap {x} {y}')
                self.note(f'HARNESS tap {kind}')
                if kind == 'doc':
                    self.note(f'HARNESS selected {label}')
                    return
            time.sleep(1)
        raise Harness(f'{self.name}: document {label} never appeared in the picker')

    def back(self, label):
        self.picker_focused()
        shell('input keyevent KEYCODE_BACK')
        self.note(f'HARNESS back {label}')

    def start(self):
        adb('logcat', '-c')
        shell(f'am force-stop {PKG}')
        shell(f'am start -n {ACT} --es scenario {self.name.split("@")[0]} --ez fresh true')
        self.note('HARNESS started')

    def finish(self, extra=''):
        time.sleep(2)
        (self.out / f'{self.name}.log').write_text(logcat())
        (self.out / f'crash-{self.name}.txt').write_text(adb('logcat', '-d', '-b', 'crash'))
        self.dump('final')
        (self.out / f'{self.name}.png').write_bytes(adb('exec-out', 'screencap', '-p', binary=True))
        self.drive.close()


def complete(r):
    r.wait_for(r'CHECK phase_complete true', 60, 'phase_complete')


def sc_normal(r):
    r.start()
    r.wait_for(r'MARK pick_1', what='pick_1'); r.select('fixture-a.txt', 'a')
    r.wait_for(r'MARK pick_2', what='pick_2'); r.select('fixture-b.txt', 'b')
    r.wait_for(r'MARK pick_3', what='pick_3'); r.back('cancel')
    complete(r)


def sc_errors(r):
    r.start()
    r.wait_for(r'MARK pick_1', what='pick_1'); r.select('fixture-bad.bin', 'bad')
    r.wait_for(r'MARK pick_2', what='pick_2'); r.select('fixture-big.bin', 'big')
    complete(r)


def sc_rotation(r):
    r.start()
    r.wait_for(r'MARK picker_open', what='picker_open'); r.picker_focused()
    shell('settings put system accelerometer_rotation 0'); shell('settings put system user_rotation 1')
    r.note('HARNESS rotated landscape'); time.sleep(3)
    try:
        r.select('fixture-a.txt', 'a')
    finally:
        shell('settings put system user_rotation 0'); shell('settings put system accelerometer_rotation 1')
    complete(r)


def sc_recreate(r):
    """Activity.recreate() while the picker is open. Either outcome is checked by verify.py, whichever the engine did."""
    r.start()
    r.wait_for(r'MARK picker_open', what='picker_open'); r.picker_focused()
    # recreate() is requested by the fixture driver from Dart after pick; here the harness uses the OS equivalent:
    # a configuration change (font scale) delivers a real recreation to the app behind the picker.
    shell('settings put system font_scale 1.3'); r.note('HARNESS config change font_scale'); time.sleep(3)
    try:
        r.select('fixture-a.txt', 'a')
    finally:
        shell('settings put system font_scale 1.0')
    complete(r)


def sc_stale_recreate(r):
    """Retire the caller (engine and activity destroyed and recreated by a real configuration change) while the picker is open,
    PROVE it happened from the lifecycle log, and only then select the old document."""
    r.start()
    r.wait_for(r'MARK old_picker_open', what='old_picker_open'); r.picker_focused()
    shell('settings put system font_scale 1.3'); r.note('HARNESS config change font_scale')
    try:
        r.wait_for(r'ENGINE cleanup 1[\s\S]*ACT create \d+ restored true[\s\S]*ENGINE configure 2', 30, 'caller retired and recreated while the picker is open')
        r.note('HARNESS recreated_before_selection')
        r.picker_focused()
        r.select('fixture-a.txt', 'a')
        r.wait_for(r'MARK pick_2', 90, 'pick_2 from the recreated engine'); r.select('fixture-b.txt', 'b')
        complete(r)
    finally:
        shell('settings put system font_scale 1.0')


def kill_app(r):
    """Real process death: SIGKILL the debuggable app's own process. The picker is another app's process and survives."""
    before = pid()
    r.note(f'HARNESS pid_before {before}')
    if not before:
        raise Harness(f'{r.name}: no app process to kill')
    shell(f'run-as {PKG} kill -9 {before}')
    time.sleep(3)
    after = pid()
    r.note(f'HARNESS pid_after_kill {after or "none"}')
    if after == before:
        raise Harness(f'{r.name}: the app process survived kill -9; process death was not exercised')
    return before


def sc_stale_kill(r):
    r.start()
    r.wait_for(r'MARK old_picker_open', what='old_picker_open'); r.picker_focused()
    kill_app(r)
    r.note('HARNESS killed_before_selection')
    r.picker_focused()
    r.select('fixture-a.txt', 'a')
    r.wait_for(r'MARK pick_2', 90, 'pick_2 from the restored process'); r.note(f'HARNESS pid_after_restore {pid()}')
    r.select('fixture-b.txt', 'b')
    complete(r)


def main(out):
    out = pathlib.Path(out); out.mkdir(parents=True, exist_ok=True)
    failures = []
    for name in SCENARIOS:
        r = Run(out, name)
        try:
            globals()['sc_' + name](r)
        except Harness as e:
            r.note(f'HARNESS FAILED {e}'); failures.append(str(e))
        except Exception as e:  # keep the evidence for the other scenarios
            r.note(f'HARNESS EXCEPTION {type(e).__name__}'); failures.append(f'{name}: {type(e).__name__}')
        finally:
            try:
                r.finish()
            except Exception:
                pass
    if failures:
        print('HARNESS failures:\n' + '\n'.join(failures)); sys.exit(2)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'picker-out')
