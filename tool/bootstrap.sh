#!/usr/bin/env bash
set -euo pipefail
# Generated platform hosts are temporary until stable package/signing identity is
# selected. Reproducible source lives in lib/, test/ and the pinned pubspec lock.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
flutter create --platforms=android,web,linux,windows,macos --org org.otpanda.development --project-name otpanda_client "$tmp/host"
for platform in android web linux windows macos; do
  if [ ! -d "$platform" ]; then cp -R "$tmp/host/$platform" "$platform"; fi
done
# Never mislabel a debug-key signature as a trusted release.
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/build.gradle.kts')
s=p.read_text().replace('            signingConfig = signingConfigs.getByName("debug")\n','')
p.write_text(s)
PY
flutter pub get
