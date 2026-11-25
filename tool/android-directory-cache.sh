#!/usr/bin/env bash
# Android acceptance for the cached 2FA Directory catalogue and logos: real
# path_provider cache directory, real network, then a cold directory from
# disk with the network blocked, the picker, and the bounds. Needs an
# emulator or device with internet. Screenshots land in OUT/shots/*.png.
#
#   tool/android-directory-cache.sh [out-dir]
set -euo pipefail
OUT="${1:-directory-cache-out}"
mkdir -p "$OUT"
set +e
flutter test integration_test/service_directory_android_test.dart --flavor google -d "${DEVICE:-emulator-5554}" 2>&1 | tee "$OUT/test.log"
result=${PIPESTATUS[0]}
set -e
python3 "$(dirname "$0")/extract-shots.py" "$OUT/test.log" "$OUT/shots"
exit "$result"
