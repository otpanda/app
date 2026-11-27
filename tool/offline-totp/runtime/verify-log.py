#!/usr/bin/env python3
"""Fail-closed verifier for the emulator fixture log. Usage: verify-log.py LOG EXPECTED_API. Exit 0 only if every check holds."""
import re, sys
PHASES = ["env", "secure-default", "seam-provision", "seam-restart", "seam-loss", "seam-orphan", "size", "cleanup", "v2-capability", "v2-provision", "v2-restart", "v2-rotate", "v2-pending", "v2-pending-retry", "v2-metadata", "v2-keylen", "v2-cleanup", "v3-vault", "v3-enroll", "v3-restart", "v3-status", "v3-missing", "v3-pending", "v3-pending-retry", "v3-install", "v3-cleanup"]
MIN_OKS = {"env": 0, "secure-default": 2, "seam-provision": 4, "seam-restart": 4, "seam-loss": 4, "seam-orphan": 3, "size": 0, "cleanup": 1,
            "v2-capability": 2, "v2-provision": 5, "v2-restart": 3, "v2-rotate": 8, "v2-pending": 4, "v2-pending-retry": 5, "v2-metadata": 11, "v2-keylen": 7, "v2-cleanup": 3, "v3-vault": 10, "v3-enroll": 6, "v3-restart": 5, "v3-status": 5, "v3-missing": 3, "v3-pending": 5, "v3-pending-retry": 2, "v3-install": 7, "v3-cleanup": 3}
BAD = re.compile(r"FIXTURE api=\d+ FAIL|FATAL|Aborted|INSTRUMENTATION_FAILED|Process crashed|Exception|Traceback|\bsignal \d+|Segmentation|not found|inaccessible", re.I)
def verify(text, api):
    errs = []
    if not text.strip(): return ["empty log"]
    for n, line in enumerate(text.splitlines(), 1):
        if BAD.search(line): errs.append(f"line {n}: failure marker: {line[:120]}")
    parts = re.split(r"^== phase (\S+)\s*$", text, flags=re.M)
    names, bodies = parts[1::2], parts[2::2]
    if names != PHASES: errs.append(f"phase sequence {names} != expected {PHASES}")
    for name, body in zip(names, bodies):
        ends = re.findall(r"^FIXTURE api=(\d+) END phase=(\S+) oks=(\d+)\s*$", body, flags=re.M)
        if len(ends) != 1: errs.append(f"{name}: expected exactly one END marker, got {len(ends)}"); continue
        a, p, k = ends[0]
        if p != name: errs.append(f"{name}: END marker names phase {p}")
        if a != str(api): errs.append(f"{name}: api {a} != expected {api}")
        oklines = len(re.findall(r"^FIXTURE api=\d+ ok ", body, flags=re.M))
        if oklines != int(k): errs.append(f"{name}: ok lines {oklines} != END oks {k}")
        if int(k) < MIN_OKS.get(name, 0): errs.append(f"{name}: oks {k} below minimum {MIN_OKS[name]}")
        if not body.rstrip().splitlines()[-1].startswith(f"FIXTURE api={api} END phase={name} "): errs.append(f"{name}: END marker is not the last line (truncation or trailing noise)")
        if name == "env" and not re.search(r"FIXTURE api=\d+ env fingerprint=\S", body): errs.append("env: no fingerprint line")
        if name == "secure-default" and not re.search(r"RESULT secure-default outcome=(accepted|protection_too_weak)\s*$", body, flags=re.M): errs.append("secure-default: missing or unexpected RESULT")
        if name == "size" and not re.search(r"RESULT size65 outcome=\S+", body): errs.append("size: missing size65 RESULT")
        if name == "v2-capability" and not re.search(r"RESULT v2-capability protection=(HARDWARE_HMAC|HARDWARE_WRAPPED|OS_ENCRYPTED)\b", body): errs.append("v2-capability: missing or unusable protection RESULT")
        if name == "v2-provision":
            for e in ("fxsha1", "fxsha256", "fxsha512"):
                if not re.search(rf"RESULT v2-level {e}=(secure_hardware|software)\s*$", body, flags=re.M): errs.append(f"v2-provision: missing level for {e}")
        if name == "v3-vault" and not re.search(r"RESULT v3-vault-level=(secure_hardware|software|unknown)\s*$", body, flags=re.M): errs.append("v3-vault: missing level RESULT")
        if name == "v2-keylen":
            for n in (10, 20, 32, 64, 65, 100, 128):
                if not re.search(rf"RESULT keylen {n}=\S+\s*$", body, flags=re.M): errs.append(f"v2-keylen: missing RESULT for {n}")
            if re.search(r"RESULT keylen \d+=WRONG_CODE", body): errs.append("v2-keylen: a seed produced a wrong code")
        if name == "seam-provision":
            for acct in ("fxsha1", "fxsha256", "fxsha512"):
                if not re.search(rf"RESULT level {acct}=(secure_hardware|software)\s*$", body, flags=re.M): errs.append(f"seam-provision: missing level for {acct}")
    return errs
if __name__ == "__main__":
    errs = verify(open(sys.argv[1], errors="replace").read(), sys.argv[2])
    for e in errs: print("VERIFY FAIL:", e, file=sys.stderr)
    print("VERIFY PASS" if not errs else f"VERIFY FAIL ({len(errs)})")
    sys.exit(1 if errs else 0)
