#!/bin/bash
# Real-Keychain lifecycle probe for the macOS wrapping-key core (file-based
# login keychain backend). Run on a macOS host from the repo root:
#   bash tool/desktop/macos_keychain_probe.sh
# It touches only items with service app.otpanda.wrapping-key and a random
# probe-* account, and deletes them at the end. Run it on a CI runner or a
# throwaway account, not as a drive-by on a machine whose login keychain is
# locked: nothing here shows a dialog, but results then read "locked".
#
# Exit 1 only for contract violations (same-binary read/create mismatch,
# overwrite on duplicate, diverging concurrent creates). The after-rebuild
# result is DATA (it answers whether ad-hoc upgrades keep access) and is
# printed, not asserted.
set -u
[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 2; }
SRC=tool/desktop/macos_overlay_src
D=$(mktemp -d)
SVC=app.otpanda.wrapping-key
FAIL=0
bad() { echo "VIOLATION: $*"; FAIL=1; }
run() { perl -e 'alarm 20; exec @ARGV' -- "$@" 2>&1 || echo "err kind=timeout-or-crash unknown=true"; }

build() { # out marker [explicit-DR]
  echo "let probeMarker = \"$2\"" > "$D/marker.swift"
  swiftc -parse-as-library -o "$1" "$SRC/WrappingKeyCore.swift" \
    "$SRC/WrappingKeyKeychain.swift" "$SRC/WrappingKeyProbe.swift" "$D/marker.swift" || exit 3
  if [ "${3:-}" = dr ]; then
    codesign --force -s - -i app.otpanda.probe \
      -r='designated => identifier "app.otpanda.probe"' "$1"
  else
    codesign --force -s - "$1"
  fi
  echo "  designated requirement of $(basename "$1"): $(codesign -d -r- "$1" 2>&1 | grep '^designated' )"
}

scenario() { # name dr|plain
  local name=$1 mode=$2 ns="probe-$$-$RANDOM-$1"
  echo "== scenario $name (ad-hoc signed, $mode requirement)"
  build "$D/v1-$name" a "$mode"
  local r
  r=$(run "$D/v1-$name" read "$ns");   echo "  v1 read before create : $r"
  case $r in *"key=none"*) ;; *) bad "$name: item not absent at start" ;; esac
  r=$(run "$D/v1-$name" create "$ns" 11); echo "  v1 create             : $r"
  case $r in *"key=11111111/32 created=true"*) ;; *) bad "$name: create did not store" ;; esac
  r=$(run "$D/v1-$name" read "$ns");   echo "  v1 read               : $r"
  case $r in *"key=11111111/32"*) ;; *) bad "$name: same-binary read mismatch" ;; esac
  r=$(run "$D/v1-$name" create "$ns" 22); echo "  v1 duplicate create   : $r"
  case $r in *"key=11111111/32 created=false"*) ;; *) bad "$name: duplicate overwrote or failed" ;; esac
  # Rebuild with different code (new cdhash), same identifier and signing mode.
  build "$D/v2-$name" b "$mode"
  r=$(run "$D/v2-$name" read "$ns");   echo "  DATA v2 (rebuilt) read: $r"
  r=$(run "$D/v2-$name" create "$ns" 33); echo "  DATA v2 dup create    : $r"
  # Concurrent creates from separate processes.
  local ns2="$ns-race" i out
  for i in 1 2 3 4 5 6; do run "$D/v1-$name" create "$ns2" "0$i" > "$D/race-$i" & done
  wait
  out=$(cat "$D"/race-* | sed -E 's/ created=[a-z]+//; s/ marker=.*//' | sort -u)
  echo "  race results (want one distinct line): $(echo "$out" | tr '\n' ';')"
  [ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] || bad "$name: concurrent creates diverged"
  security delete-generic-password -s "$SVC" -a "$ns" >/dev/null 2>&1
  security delete-generic-password -s "$SVC" -a "$ns2" >/dev/null 2>&1
  r=$(run "$D/v1-$name" read "$ns");   echo "  after cleanup read    : $r"
}

scenario plain plain
scenario dr dr
rm -rf "$D"
[ $FAIL = 0 ] && echo "PROBE CONTRACT OK (read the DATA lines for upgrade behaviour)" || echo "PROBE CONTRACT VIOLATED"
exit $FAIL
