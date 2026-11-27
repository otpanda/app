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
# results are DATA (they answer whether ad-hoc upgrades keep access) and are
# printed, not asserted. No scenario widens an item's ACL to all applications.
set -u
[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 2; }
SRC=tool/desktop/macos_overlay_src
D=$(mktemp -d)
SVC=app.otpanda.wrapping-key
FAIL=0
bad() { echo "VIOLATION: $*"; FAIL=1; }
run() { # bounded; prints the probe line plus elapsed seconds. A kill by the alarm is reported as TIMEOUT (a hang), never as a normal refusal.
  local t0=$(date +%s) out rc
  out=$(perl -e 'alarm 20; exec @ARGV' -- "$@" 2>&1); rc=$?
  [ $rc -eq 0 ] || out="$out TIMEOUT-or-crash rc=$rc"
  echo "$out elapsed=$(( $(date +%s) - t0 ))s"
}

build() { # out marker [explicit-DR]
  echo "let probeMarker = \"$2\"" > "$D/marker.swift"
  swiftc -parse-as-library -o "$1" "$SRC/WrappingKeyCore.swift" \
    "$SRC/WrappingKeyKeychain.swift" "$SRC/WrappingKeyProbe.swift" "$SRC/WrappingKeyProbeTrust.swift" "$D/marker.swift" || exit 3
  if [ "${3:-}" = dr ]; then
    codesign --force -s - -i app.otpanda.probe \
      -r='designated => identifier "app.otpanda.probe"' "$1"
  else
    codesign --force -s - "$1"
  fi
  echo "  designated requirement of $(basename "$1"): $(codesign -d -r- "$1" 2>&1 | grep '^designated' )"
}

dump_acl() { # ACL/partition entries of the probe item only (no secret data is requested)
  perl -e 'alarm 15; exec @ARGV' -- security dump-keychain -a 2>/dev/null | awk -v a="$1" '/^keychain:/{if(f)print blk; blk=""; f=0} {blk=blk $0 "\n"} index($0,a){f=1} END{if(f)print blk}' \
    | grep -E 'acct|description|entry [0-9]|authorizations|applications|hash|partition|ACL|ad-hoc|cdhash|path' | sed 's/^/    acl: /' | head -40
}

CERTKC=""
setup_cert() { # best effort: a local self-signed code-signing identity in a throwaway keychain
  CERTKC="$D/probe-cert.keychain-db"; local pw=probe-pw
  cat > "$D/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=otpanda probe codesign
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/k.pem" -out "$D/c.pem" -days 2 -config "$D/cert.cnf" >/dev/null 2>&1 || return 1
  openssl pkcs12 -export -inkey "$D/k.pem" -in "$D/c.pem" -out "$D/id.p12" -passout pass:p -name "otpanda probe codesign" >/dev/null 2>&1 || return 1
  CERTSHA=$(openssl x509 -in "$D/c.pem" -outform DER | shasum -a 1 | cut -d' ' -f1 | tr a-f A-F)
  security create-keychain -p "$pw" "$CERTKC" && security set-keychain-settings "$CERTKC" && security unlock-keychain -p "$pw" "$CERTKC" || return 1
  security import "$D/id.p12" -k "$CERTKC" -P p -T /usr/bin/codesign >/dev/null 2>&1 || return 1
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$CERTKC" >/dev/null 2>&1 || return 1
  OLDLIST=$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')
  security list-keychains -d user -s "$CERTKC" $OLDLIST || return 1
}
teardown_cert() { [ -n "$CERTKC" ] && { security list-keychains -d user -s $OLDLIST >/dev/null 2>&1; security delete-keychain "$CERTKC" >/dev/null 2>&1; }; }

build_cert() { # out marker : stable identity = identifier + certificate leaf hash
  echo "let probeMarker = \"$2\"" > "$D/marker.swift"
  swiftc -parse-as-library -o "$1" "$SRC/WrappingKeyCore.swift" "$SRC/WrappingKeyKeychain.swift" "$SRC/WrappingKeyProbe.swift" "$SRC/WrappingKeyProbeTrust.swift" "$D/marker.swift" || exit 3
  codesign --force -s "otpanda probe codesign" -i app.otpanda.probe \
    -r="designated => identifier \"app.otpanda.probe\" and certificate leaf = H\"$CERTSHA\"" "$1" 2>&1 | head -3
  echo "  designated requirement of $(basename "$1"): $(codesign -d -r- "$1" 2>&1 | grep '^designated')"
}

# Upgrade matrix. v1 creates the item. Then, every row is a bounded no-prompt read and duplicate create:
#   copy      : the SAME signed binary at a different path (separates path from code identity)
#   other     : rebuilt code at a DIFFERENT path
#   samepath  : rebuilt code at the SAME path as v1 (the real app-upgrade shape), done last because it replaces v1
matrix() { # name plain|dr|cert
  local name=$1 mode=$2 ns="probe-$$-$RANDOM-$1" r ns2 i out; ns2="$ns-race"
  echo "== scenario $name (signing: $mode)"
  mkdir -p "$D/p1-$name" "$D/p2-$name"
  local v1="$D/p1-$name/probe"
  if [ "$mode" = cert ]; then build_cert "$v1" a; else build "$v1" a "$mode"; fi
  r=$(run "$v1" read "$ns");        echo "  v1 read before create : $r"
  case $r in *"key=none"*) ;; *) bad "$name: item not absent at start" ;; esac
  r=$(run "$v1" create "$ns" 11);   echo "  v1 create             : $r"
  case $r in *"key=11111111/32 created=true"*) ;; *) bad "$name: create did not store" ;; esac
  r=$(run "$v1" read "$ns");        echo "  v1 read               : $r"
  case $r in *"key=11111111/32"*) ;; *) bad "$name: same-binary read mismatch" ;; esac
  r=$(run "$v1" create "$ns" 22);   echo "  v1 duplicate create   : $r"
  case $r in *"key=11111111/32 created=false"*) ;; *) bad "$name: duplicate overwrote or failed" ;; esac
  dump_acl "$ns"
  # Concurrent creates from separate processes (fresh namespace, before v1 is replaced).
  
  for i in 1 2 3 4 5 6; do run "$v1" create "$ns2" "0$i" > "$D/race-$name-$i" & done
  wait
  out=$(cat "$D"/race-$name-* | sed -E 's/ created=[a-z]+//; s/ marker=.*//; s/ elapsed=.*//' | sort -u)
  echo "  race results (want one distinct line): $(echo "$out" | tr '\n' ';')"
  [ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] || bad "$name: concurrent creates diverged"
  cp "$v1" "$D/p2-$name/copy"
  r=$(run "$D/p2-$name/copy" read "$ns");  echo "  DATA copy@other-path read   : $r"
  r=$(run "$D/p2-$name/copy" create "$ns" 33); echo "  DATA copy@other-path dup    : $r"
  if [ "$mode" = cert ]; then build_cert "$D/p2-$name/other" b; else build "$D/p2-$name/other" b "$mode"; fi
  r=$(run "$D/p2-$name/other" read "$ns"); echo "  DATA rebuilt@other-path read: $r"
  r=$(run "$D/p2-$name/other" create "$ns" 33); echo "  DATA rebuilt@other-path dup : $r"
  if [ "$mode" = cert ]; then build_cert "$v1" c; else build "$v1" c "$mode"; fi
  r=$(run "$v1" read "$ns");        echo "  DATA rebuilt@SAME-path read : $r"
  r=$(run "$v1" create "$ns" 33);   echo "  DATA rebuilt@SAME-path dup  : $r"
  # The original key must still be intact after every refused attempt (read through the trusted original is gone: the same path now holds new code),
  # so verify with the OS tool that the item still exists. Its data is not printed.
  if security find-generic-password -s "$SVC" -a "$ns" >/dev/null 2>&1; then echo "  item still present after all attempts: yes"; else bad "$name: item vanished"; fi
  security delete-generic-password -s "$SVC" -a "$ns2" >/dev/null 2>&1
  security delete-generic-password -s "$SVC" -a "$ns" >/dev/null 2>&1
  security delete-generic-password -s "$SVC" -a "$ns2" >/dev/null 2>&1
}

# Handoff experiment (plain ad-hoc only): the trusted v1 appends a STAGED next build to the item's decrypt ACL, the staged build is then moved over v1's
# path (the in-place upgrade shape), and read/duplicate-create are measured. Only one named binary is appended; nothing is opened to all applications.
handoff() {
  local ns="probe-$$-$RANDOM-handoff" r v1="$D/ph/probe" st="$D/ph/staged"
  echo "== scenario handoff (plain ad-hoc; v1 trusts the staged next build before the in-place replace)"
  mkdir -p "$D/ph"; build "$v1" a plain
  r=$(run "$v1" create "$ns" 11); echo "  v1 create             : $r"
  build "$st" b plain
  r=$(run "$st" read "$ns");      echo "  DATA staged read BEFORE trust (expect denied): $r"
  r=$(run "$v1" trust "$ns" "$st"); echo "  DATA v1 trust staged  : $r"
  # Never run diagnostics after the ACL mutation: the isolated v4 attempt hung here.
  r=$(run "$st" read "$ns");      echo "  DATA staged read AFTER trust : $r"
  mv -f "$st" "$v1"
  r=$(run "$v1" read "$ns");      echo "  DATA in-place replaced read  : $r"
  r=$(run "$v1" create "$ns" 33); echo "  DATA in-place replaced dup   : $r"
  if security find-generic-password -s "$SVC" -a "$ns" >/dev/null 2>&1; then echo "  item still present: yes"; else bad "handoff: item vanished"; fi
  security delete-generic-password -s "$SVC" -a "$ns" >/dev/null 2>&1
}
if [ "${OTPANDA_PROBE_HANDOFF:-0}" = 1 ]; then
  handoff
else
  echo "== scenario handoff SKIPPED (OTPANDA_PROBE_HANDOFF not enabled): prior attempt timed out, continuity UNPROVEN"
fi

matrix plain plain
matrix dr dr
if [ "${OTPANDA_PROBE_THROWAWAY_CERT:-0}" = 1 ]; then
  if setup_cert; then matrix cert cert; else echo "== scenario cert SKIPPED (could not create a throwaway signing identity here): data only"; fi
else
  echo "== scenario cert SKIPPED (OTPANDA_PROBE_THROWAWAY_CERT not enabled): data only"
fi
teardown_cert
rm -rf "$D"
[ $FAIL = 0 ] && echo "PROBE CONTRACT OK (read the DATA lines for upgrade behaviour)" || echo "PROBE CONTRACT VIOLATED"
exit $FAIL
