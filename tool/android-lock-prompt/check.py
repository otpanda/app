#!/usr/bin/env python3
"""Source guard (not OS evidence): the fixture is debug-source-set only, production uses the default fixed-origin transport, and nothing can swap it."""
import re
from pathlib import Path
r = Path(__file__).resolve().parent.parent.parent
host = (r / 'tool/android-native/main/LocalLockRecoveryHost.kt').read_text()
main = (r / 'tool/android-native/main/MainActivity.kt').read_text()
inst = (r / 'tool/android-lock-prompt/install-fixture.py').read_text()
dbg = r / 'tool/android-lock-prompt/debug'
fx = '\n'.join(p.read_text() for p in dbg.glob('*.kt'))
# 1. The seam is a default parameter, nothing else.
assert 'fun register(activity: Activity, messenger: BinaryMessenger, api: LockApi = HttpsLockApi())' in host
assert 'LocalLockRecovery(api, Passkeys' in host and host.count('HttpsLockApi()') == 1
body = host.split('object LocalLockRecoveryHost', 1)[1]
for bad in ('System.getProperty', 'getStringExtra', 'getIntent', 'Class.forName', 'BuildConfig', 'var api', 'lateinit', '@JvmStatic', 'internal var'):
    assert bad not in body, bad
assert len(re.findall(r'\bvar\b', body.split('private class Env')[0])) == 4  # recovery, io, disposed, channel (unchanged state)
# 2. Production call site is the 2-argument default and MainActivity is only made open.
calls = [l for l in main.splitlines() if 'LocalLockRecoveryHost.register(' in l]
assert calls == ['        LocalLockRecoveryHost.register(this, flutterEngine.dartExecutor.binaryMessenger)'], calls
assert re.search(r'^open class MainActivity : FlutterActivity\(\)', main, re.M)
# 3. Fake/synthetic classes exist only in the debug fixture folder; the installer writes only the debug source set.
assert "'android/app/src/debug'" in inst and 'src/main' not in inst and 'src/release' not in inst
for p in list((r / 'tool/android-native').rglob('*.kt')) + list((r / 'tool/android-recovery').glob('*.kt')) + list((r / 'lib').rglob('*.dart')):
    t = p.read_text()
    for bad in ('FakeLockApi', 'LockPromptHostActivity', 'SyntheticProvider', 'SyntheticAssertion', 'app.otpanda.fixture', 'fixture-bearer'):
        assert bad not in t, (p, bad)
# 4. The fixture uses the real host, real MainActivity, no network, no real storage of keys.
assert 'class LockPromptHostActivity : MainActivity()' in fx and 'LocalLockRecoveryHost.register(this, l, FakeLockApi(' in fx
for bad in ('HttpsLockApi', 'HttpURLConnection', 'URL(', 'KeyStore', 'AndroidKeyStore'):
    assert bad not in fx, bad
assert 'KeyPairGenerator.getInstance("EC")' in fx and 'initSign' in fx  # throwaway in-memory key per call
print('PASS lock-prompt fixture source guard (not OS evidence)')
