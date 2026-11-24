#!/usr/bin/env python3
"""Make the generated Flutter Android project sign release builds.

Reads RELEASE_STORE_FILE, RELEASE_STORE_PASSWORD, RELEASE_KEY_ALIAS and
RELEASE_KEY_PASSWORD from the environment, writes android/key.properties and
patches android/app/build.gradle.kts. Used by the release workflow (with the
real key) and by the pull request check (with a throwaway key), so a broken
patch fails before a release is tagged.
"""
import os
import sys
from pathlib import Path

names = ['RELEASE_STORE_FILE', 'RELEASE_STORE_PASSWORD', 'RELEASE_KEY_ALIAS', 'RELEASE_KEY_PASSWORD']
missing = [n for n in names if not os.environ.get(n)]
if missing:
    sys.exit('Missing environment: ' + ', '.join(missing))

Path('android/key.properties').write_text(
    'storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n'
    % (os.environ['RELEASE_STORE_FILE'], os.environ['RELEASE_STORE_PASSWORD'],
       os.environ['RELEASE_KEY_ALIAS'], os.environ['RELEASE_KEY_PASSWORD'])
)

p = Path('android/app/build.gradle.kts')
s = p.read_text()
block = (
    '    signingConfigs {\n'
    '        create("release") {\n'
    '            val props = Properties()\n'
    '            props.load(FileInputStream(rootProject.file("key.properties")))\n'
    '            storeFile = file(props.getProperty("storeFile"))\n'
    '            storePassword = props.getProperty("storePassword")\n'
    '            keyAlias = props.getProperty("keyAlias")\n'
    '            keyPassword = props.getProperty("keyPassword")\n'
    '        }\n'
    '    }\n'
)
assert 'buildTypes {' in s and 'release {' in s, 'unexpected Gradle template'
s = s.replace('    buildTypes {', block + '    buildTypes {', 1)
s = s.replace('        release {\n', '        release {\n            signingConfig = signingConfigs.getByName("release")\n', 1)
s = 'import java.io.FileInputStream\nimport java.util.Properties\n\n' + s
p.write_text(s)
print('Patched android/app/build.gradle.kts for release signing')
