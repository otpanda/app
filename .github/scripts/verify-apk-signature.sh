#!/usr/bin/env bash
# Verify an APK signature with the Android SDK apksigner and print the signer certificate.
set -uo pipefail
apk="$1"
apksigner=""
for root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" /usr/local/lib/android/sdk "$HOME/.android" "$HOME/android-sdk"; do
  [ -n "$root" ] && [ -d "$root" ] || continue
  found=$(find "$root" -name apksigner -type f 2>/dev/null | sort -V | tail -1)
  if [ -n "$found" ]; then apksigner="$found"; break; fi
done
echo "apksigner: ${apksigner:-not found}"
[ -n "$apksigner" ] || { echo "::error::apksigner not found in the Android SDK"; exit 1; }
out=$("$apksigner" verify --verbose --print-certs "$apk" 2>&1)
status=$?
echo "$out" | grep -E 'Verifies|certificate (SHA-256|DN)|ERROR|DOES NOT' || true
[ "$status" -eq 0 ] || { echo "::error::apksigner verify failed (exit $status)"; echo "$out" | head -20; exit 1; }

[ -n "${EXPECTED_CERT_SHA256:-}" ] || { echo '::error::Expected signing certificate is required'; exit 1; }
  actual=$(printf '%s\n' "$out" | sed -n 's/^.*certificate SHA-256 digest: //p' | tr -d ':' | tr '[:upper:]' '[:lower:]')
  expected=$(printf '%s' "$EXPECTED_CERT_SHA256" | tr -d ':' | tr '[:upper:]' '[:lower:]')
  [ "$actual" = "$expected" ] || { printf '::error::APK signing certificate mismatch (actual=%s expected=%s)\n' "$actual" "$expected"; exit 1; }
