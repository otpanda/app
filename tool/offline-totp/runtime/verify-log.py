#!/usr/bin/env python3
"""Fail-closed verifier for the emulator fixture log. Usage: verify-log.py LOG EXPECTED_API. Exit 0 only if every check holds."""
import re, sys
PHASES = ["env", "secure-default", "seam-provision", "seam-restart", "seam-loss", "seam-orphan", "size", "cleanup"]
MIN_OKS = {"env": 0, "secure-default": 2, "seam-provision": 4, "seam-restart": 4, "seam-loss": 4, "seam-orphan": 3, "size": 0, "cleanup": 1}
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
        if name == "seam-provision":
            for acct in ("fxsha1", "fxsha256", "fxsha512"):
                if not re.search(rf"RESULT level {acct}=(secure_hardware|software)\s*$", body, flags=re.M): errs.append(f"seam-provision: missing level for {acct}")
    return errs
if __name__ == "__main__":
    errs = verify(open(sys.argv[1], errors="replace").read(), sys.argv[2])
    for e in errs: print("VERIFY FAIL:", e, file=sys.stderr)
    print("VERIFY PASS" if not errs else f"VERIFY FAIL ({len(errs)})")
    sys.exit(1 if errs else 0)
