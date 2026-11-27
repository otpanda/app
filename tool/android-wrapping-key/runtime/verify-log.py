#!/usr/bin/env python3
"""Fail-closed verifier for the wrapping-key emulator fixture log. Usage: verify-log.py LOG EXPECTED_API | verify-log.py --phases. Exit 0 only if every check holds.
A kill in crash-start is expected: it kills a SERVICE process, not the instrumentation process, so every phase must still end cleanly."""
import re, sys
PHASES = ["env", "create", "reopen", "duplicate", "alias-lost", "alias-lost-restart", "corrupt", "orphan", "threads", "race-procs", "crash-start", "crash-recover", "delete", "cleanup"]
MIN_OKS = {"env": 3, "create": 6, "reopen": 3, "duplicate": 1, "alias-lost": 5, "alias-lost-restart": 3, "corrupt": 7, "orphan": 3, "threads": 4, "race-procs": 5,
           "crash-start": 4, "crash-recover": 4, "delete": 2, "cleanup": 1}
BAD = re.compile(r"FIXTURE api=\d+ FAIL|FATAL|Aborted|INSTRUMENTATION_FAILED|Process crashed|Exception|Traceback|\bsignal \d+|Segmentation|not found|inaccessible|\(got |\(no failure\)|FAILED", re.I)
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
        if not body.rstrip().splitlines()[-1].startswith(f"FIXTURE api={api} END phase={name} "): errs.append(f"{name}: END marker is not the last line")
        if name == "env" and not re.search(r"FIXTURE api=\d+ env fingerprint=\S", body): errs.append("env: no fingerprint line")
        if name == "race-procs" and not re.search(r"ok exactly one process created the key", body): errs.append("race-procs: missing single-creator check")
        if name == "alias-lost" and not re.search(r"ok read with blob but no alias -> MISSING_ALIAS", body): errs.append("alias-lost: missing MISSING_ALIAS read check")
        if name == "corrupt" and not re.search(r"ok flipped tag byte -> CORRUPT", body): errs.append("corrupt: missing CORRUPT check")
    return errs
if __name__ == "__main__":
    if sys.argv[1:] == ["--phases"]: print(" ".join(PHASES)); sys.exit(0)
    errs = verify(open(sys.argv[1], errors="replace").read(), sys.argv[2])
    for e in errs: print("VERIFY FAIL:", e, file=sys.stderr)
    print("VERIFY PASS" if not errs else f"VERIFY FAIL ({len(errs)})")
    sys.exit(1 if errs else 0)
