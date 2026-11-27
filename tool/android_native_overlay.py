#!/usr/bin/env python3
"""Idempotent Android native overlay, run by tool/bootstrap.sh after the host is
generated and renamed to app.otpanda. Copies the tracked Kotlin sources, adds the
credentials dependencies and the HTTPS App Link return filter. No signer, key or
account material lives here."""
import shutil
from pathlib import Path
root = Path('android/app/src')
here = Path(__file__).parent / 'android-native'
for flavor in ('main', 'google', 'fdroid'):
    dst = root / flavor / 'kotlin' / 'app' / 'otpanda'
    dst.mkdir(parents=True, exist_ok=True)
    for f in (here / flavor).glob('*.kt'):
        shutil.copyfile(f, dst / f.name)
# The OS-gated enrolled-device key (inactive; nothing in Dart calls it yet).
rec = root / 'main' / 'kotlin' / 'org' / 'otpanda' / 'recovery'
rec.mkdir(parents=True, exist_ok=True)
for f in (Path(__file__).parent / 'android-recovery').glob('*.kt'):
    if not f.name.endswith('Test.kt'):
        shutil.copyfile(f, rec / f.name)
# Composed custody/sync/admission host is registered by reviewed MainActivity.
custody = root / 'main' / 'kotlin' / 'org' / 'otpanda' / 'totp'
custody.mkdir(parents=True, exist_ok=True)
for name in ('TotpCalculator.kt', 'SeedCustody.kt', 'AndroidSeedVault.kt',
             'NativeCustody.kt', 'NativeCustodyChannel.kt', 'OwnerStateFileStore.kt',
             'SeedSyncKey.kt', 'SeedSyncWire.kt', 'SeedSyncHandle.kt', 'SeedSyncChannel.kt',
             'InstallId.kt', 'AndroidInstallIdStore.kt', 'WorkspaceAdmission.kt', 'WorkspaceAdmissionChannel.kt', 'AndroidWorkspaceAdmissionStore.kt', 'AndroidSyncKeyVault.kt', 'SeedSyncStateFileStore.kt'):
    shutil.copyfile(Path(__file__).parent / 'offline-totp' / name, custody / name)
g = Path('android/app/build.gradle.kts'); s = g.read_text()
if 'androidx.credentials:credentials:' not in s:
    s = s.rstrip('\n') + '''

dependencies {
    // Core Credential Manager (passkeys) has no Google Play Services dependency,
    // so both flavors carry it. The Play Services bridge and Google ID are google-only.
    implementation("androidx.credentials:credentials:1.3.0")
    "googleImplementation"("androidx.credentials:credentials-play-services-auth:1.3.0")
    "googleImplementation"("com.google.android.libraries.identity.googleid:googleid:1.1.1")
}
'''
    g.write_text(s)
m = Path('android/app/src/main/AndroidManifest.xml'); t = m.read_text()
if 'android:path="/app-return"' not in t:
    flt = '''            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="https" android:host="otpanda-api.abrahammurciano.workers.dev" android:path="/app-return"/>
            </intent-filter>
'''
    t = t.replace('        </activity>', flt + '        </activity>', 1)
    m.write_text(t)
if 'android.permission.USE_BIOMETRIC' not in t:
    t = t.replace('<application', '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>\n    <application', 1)
    m.write_text(t)
# No Android auto-backup, cloud restore or device-to-device transfer of app data
# (device id, recognition file): a restored copy must never carry them without
# their Keystore keys. allowBackup=false alone does not stop device transfer on
# every Android 12+ device, so explicit rules cover both modes and every domain
# the Android Auto Backup docs list (developer.android.com/identity/data/autobackup).
import re
DOMAINS = ('file', 'database', 'sharedpref', 'external', 'root',
           'device_file', 'device_database', 'device_sharedpref', 'device_root')
excl = ''.join(f'        <exclude domain="{d}" path="."/>\n' for d in DOMAINS)
xml = m.parent / 'res' / 'xml'
xml.mkdir(parents=True, exist_ok=True)
(xml / 'data_extraction_rules.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<data-extraction-rules>\n'
    '    <cloud-backup>\n' + excl + '    </cloud-backup>\n'
    '    <device-transfer>\n' + excl + '    </device-transfer>\n'
    '</data-extraction-rules>\n')
(xml / 'backup_rules.xml').write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<full-backup-content>\n'
    + excl.replace('        ', '    ') + '</full-backup-content>\n')
t = m.read_text()
def set_attr(t, name, value):
    tag = re.search(r'<application\b[^>]*>', t, re.S).group(0)
    new = re.sub(r'\s' + re.escape(name) + r'="[^"]*"', '', tag)
    new = new.replace('<application', f'<application {name}="{value}"', 1)
    return t.replace(tag, new, 1)
for name, value in (('android:allowBackup', 'false'),
                    ('android:dataExtractionRules', '@xml/data_extraction_rules'),
                    ('android:fullBackupContent', '@xml/backup_rules')):
    t = set_attr(t, name, value)
m.write_text(t)
