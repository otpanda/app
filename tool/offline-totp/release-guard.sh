#!/usr/bin/env bash
# Fails if the software-key test seam is referenced anywhere in the repo outside the custody definition, its README and test files.
# Run in CI before any host wiring lands. Source-level guard only: it cannot see generated or obfuscated code.
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
seam='allowSoftwareKeysForTests'
bad=$(grep -rIl --exclude-dir=android --exclude-dir=.git --exclude-dir=build --exclude-dir=node_modules -- "$seam" "$root" \
  | grep -v -E '/tool/offline-totp/(SeedCustody\.kt|SeedCustodyTest\.kt|runtime/RuntimeFixture\.kt|README\.md|release-guard\.sh|check\.sh)$' || true)
if [ -n "$bad" ]; then printf 'FAIL release guard: software-key seam referenced in:\n%s\n' "$bad" >&2; exit 1; fi
# Every LocalSeedCustody construction (named or positional argument) is forbidden outside the logic, tests and the runtime fixture until
# a reviewed wiring change adds its own allowlist entry.
ctor=$(grep -rIlE --include='*.kt' --include='*.java' --include='*.dart' --exclude-dir=android --exclude-dir=.git --exclude-dir=build -- 'LocalSeedCustody[[:space:]]*\(' "$root" \
  | grep -v -E '/tool/offline-totp/(SeedCustody\.kt|SeedCustodyTest\.kt|runtime/RuntimeFixture\.kt)$' || true)
if [ -n "$ctor" ]; then printf 'FAIL release guard: LocalSeedCustody constructed outside allowed files:\n%s\n' "$ctor" >&2; exit 1; fi
# NativeSeedCustodyCore and OwnerStateFileStore are likewise unwired until a reviewed host change adds an allowlist entry.
v2=$(grep -rIlE --include='*.kt' --include='*.java' --include='*.dart' --exclude-dir=android --exclude-dir=.git --exclude-dir=build -- '(NativeSeedCustodyCore|OwnerStateFileStore|NativeCustodyChannelHandler)[[:space:]]*\(' "$root" \
  | grep -v -E '/tool/offline-totp/(NativeCustody\.kt|NativeCustodyChannel\.kt|NativeCustodyTest\.kt|SeedSyncKeyTest\.kt|OwnerStateFileStore\.kt|runtime/RuntimeFixtureV2\.kt)$|/tool/android-native/main/SeedCustodyHost\.kt$' || true)
if [ -n "$v2" ]; then printf 'FAIL release guard: native custody v2 constructed outside allowed files:\n%s\n' "$v2" >&2; exit 1; fi
# The seed-sync core and its file store are likewise unwired until a reviewed host change adds an allowlist entry.
ss=$(grep -rIlE --include='*.kt' --include='*.java' --include='*.dart' --exclude-dir=android --exclude-dir=.git --exclude-dir=build -- '(SeedSyncKeyCore|SeedSyncStateFileStore)[[:space:]]*\(|SeedSyncBatchHandle[[:space:]]*[.(]|SeedSyncWire[[:space:]]*\.|signRawForTests|signBuilt|runIfActive|testHookBeforeGuard' "$root" \
  | grep -v -E '/tool/offline-totp/(SeedSyncKey\.kt|SeedSyncWire\.kt|SeedSyncHandle\.kt|SeedSyncKeyTest\.kt|SeedSyncStateFileStore\.kt)$' || true)
if [ -n "$ss" ]; then printf 'FAIL release guard: seed-sync core or store constructed outside allowed files:\n%s\n' "$ss" >&2; exit 1; fi
# Unregistered host must remain unreferenced until a reviewed wiring change.
hostrefs=$(grep -rIl --include='*.kt' --include='*.java' --include='*.dart' --exclude-dir=android --exclude-dir=.git --exclude-dir=build -- 'SeedCustodyHost' "$root" \
  | grep -v -E '/tool/android-native/main/SeedCustodyHost\.kt$' || true)
if [ -n "$hostrefs" ]; then printf 'FAIL release guard: inactive custody host referenced in:\n%s\n' "$hostrefs" >&2; exit 1; fi
# The only constructor default must stay secure.
grep -q "allowSoftwareKeysForTests: Boolean = false" "$root/tool/offline-totp/SeedCustody.kt" || { echo 'FAIL release guard: seam default is not false' >&2; exit 1; }
echo 'PASS release guard: software-key seam only in custody definition, README and tests; default false'
