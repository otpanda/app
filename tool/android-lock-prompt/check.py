#!/usr/bin/env python3
"""Source guard: fixture is debug-only, synthetic, and uses the same Credential Manager call as the host. Not OS evidence."""
from pathlib import Path
r = Path(__file__).resolve().parent.parent.parent
fx = (r / 'tool/android-lock-prompt/LockPromptFixtureActivity.kt').read_text()
host = (r / 'tool/android-native/main/LocalLockRecoveryHost.kt').read_text()
inst = (r / 'tool/android-lock-prompt/install-fixture.py').read_text()
for call in ('GetCredentialRequest.Builder().addCredentialOption(GetPublicKeyCredentialOption(requestJson)).build()', 'CredentialManager.create('):
    assert call in fx and call in host, call
assert "'android/app/src/debug'" in inst and 'src/main' not in inst
for bad in ('HttpsLockApi', 'URL(', 'HttpURLConnection', 'getSharedPreferences', 'KeyStore', 'device_id'):
    assert bad not in fx, bad
assert 'ApiUnreachable()' in fx and '"fixture-bearer-not-a-real-token"' in fx
for p in (r / 'tool/android-native').rglob('*.kt'): assert 'LockPromptFixture' not in p.read_text()
print('PASS lock-prompt fixture source guard (not OS evidence)')
