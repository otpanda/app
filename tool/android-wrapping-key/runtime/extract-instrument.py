#!/usr/bin/env python3
"""Turns raw `am instrument -w` output for ONE phase into fixture-log lines. Fail closed: unknown lines are kept (the verifier then rejects them),
and a missing or non -1 INSTRUMENTATION_CODE appends a FAIL line. Usage: extract-instrument.py PHASE API < raw"""
import re, sys
def extract(raw, api):
    out, codes = [], []
    for line in raw.replace("\r", "").splitlines():
        line = re.sub(r"^INSTRUMENTATION_STATUS: stream=", "", line)
        if not line.strip() or re.match(r"INSTRUMENTATION_STATUS_CODE: ", line): continue
        m = re.match(r"INSTRUMENTATION_CODE: (-?\d+)$", line)
        if m: codes.append(m.group(1)); continue
        out.append(line)
    if codes != ["-1"]: out.append(f"FIXTURE api={api} FAIL instrumentation code {codes or 'missing'}")
    return out
if __name__ == "__main__":
    print("\n".join(extract(sys.stdin.read(), sys.argv[2])))
