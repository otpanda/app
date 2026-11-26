#!/usr/bin/env python3
"""Source regression checks for the composed native local-lock boundary."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
host = (root / 'tool/android-native/main/AppLockHost.kt').read_text()
main = (root / 'tool/android-native/main/MainActivity.kt').read_text()
recovery = (root / 'tool/android-native/main/LocalLockRecoveryHost.kt').read_text()
dart = (root / 'lib/native/native_app_lock.dart').read_text()
transport = (root / 'tool/android-recovery/HttpsLockApi.kt').read_text()
for forbidden in ('disableAfterPasskey', 'PasskeyDisablePlatform'):
    assert forbidden not in host + dart
for method in ('writeDeviceId', 'clearDeviceId'):
    line = next(x for x in main.splitlines() if '"' + method + '" ->' in x)
    assert 'LocalLockRecoveryHost.reset()' in line
assert 'override fun onStop(){LocalLockRecoveryHost.reset()' in main
assert 'override fun onDestroy(){LocalLockRecoveryHost.reset()' in main
assert 'cleanUpFlutterEngine' in main and 'LocalLockRecoveryHost.dispose()' in main
assert 'LocalLockRecoveryHost.register(this,' in main
assert 'AppLockHost.reset(); activity.window.clearFlags' in recovery
assert 'final saved = await platform.enabled();' in dart
assert 'java.net.CookieHandler.getDefault() != null' in transport
assert transport.index('sent = true') < transport.index('output.use')
print('PASS native local-lock composed source boundary guard (not OS evidence)')
# Test-only root injection must never become a production entry point.
import re
for path in (root / 'lib').rglob('*.dart'):
    if path.name == 'native_root_io.dart':
        continue
    assert not re.search(r'buildAndroidNativeRootForTest|sessionOverride|requestOverride', path.read_text()), str(path)
print('PASS test-only root injection excluded from other production sources')
