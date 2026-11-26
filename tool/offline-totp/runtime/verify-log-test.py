#!/usr/bin/env python3
"""Negative tests for verify-log.py using synthetic logs. Proves the verifier fails closed; says nothing about a real emulator."""
import importlib.util, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("v", os.path.join(here, "verify-log.py")); v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
API = 34
def phase(name, oks, extra=()):
    lines = [f"== phase {name}"]
    lines += [f"FIXTURE api={API} {e}" for e in extra]
    lines += [f"FIXTURE api={API} ok check {i}" for i in range(oks)]
    lines.append(f"FIXTURE api={API} END phase={name} oks={oks}")
    return "\n".join(lines)
EXTRA = {"env": ["env fingerprint=generic/x"], "secure-default": ["RESULT secure-default outcome=protection_too_weak"], "size": ["RESULT size65 outcome=accepted"],
         "seam-provision": [f"RESULT level {a}=software" for a in ("fxsha1", "fxsha256", "fxsha512")]}
def good(): return {n: phase(n, max(v.MIN_OKS[n], 1) if v.MIN_OKS[n] else 0, EXTRA.get(n, ())) for n in v.PHASES}
def log(d): return "\n".join(d[n] for n in v.PHASES) + "\n"
assert v.verify(log(good()), API) == [], v.verify(log(good()), API)
def expect_fail(name, text, api=API):
    assert v.verify(text, api), f"verifier accepted: {name}"
expect_fail("empty", "")
g = good(); del g["size"]; expect_fail("missing phase", "\n".join(g[n] for n in v.PHASES if n in g))
g = good(); g["seam-loss"] = g["seam-loss"].rsplit("\n", 1)[0]; expect_fail("missing END", log(g))
g = good(); g["seam-loss"] += "\n" + g["seam-loss"].splitlines()[-1]; expect_fail("duplicate END", log(g))
g = good(); g["seam-restart"] = phase("seam-restart", 1); expect_fail("too few oks", log(g))
g = good(); g["cleanup"] = g["cleanup"].replace("oks=1", "oks=0"); expect_fail("ok count mismatch", log(g))
g = good(); g["env"] += f"\nFIXTURE api={API} FAIL something"; expect_fail("FAIL line", log(g))
for marker in ("FATAL EXCEPTION: main", "Aborted", "java.lang.NullPointerException", "Segmentation fault"):
    g = good(); g["size"] = g["size"].replace("RESULT size65", marker + "\nFIXTURE api=34 RESULT size65"); expect_fail(marker, log(g))
g = good(); g["secure-default"] = phase("secure-default", 2); expect_fail("missing secure-default RESULT", log(g))
g = good(); g["size"] = phase("size", 0); expect_fail("missing size65", log(g))
g = good(); g["seam-provision"] = phase("seam-provision", 4, EXTRA["seam-provision"][:2]); expect_fail("missing level marker", log(g))
g = good(); g["seam-provision"] = phase("seam-provision", 4, [x.replace("software", "null") for x in EXTRA["seam-provision"]]); expect_fail("null level", log(g))
expect_fail("wrong api", log(good()), api=30)
g = good(); g["env"] = g["env"] + "\ntrailing noise"; expect_fail("trailing noise", log(g))
g = good(); g["env"] = g["env"].replace("END phase=env", "END phase=cleanup"); expect_fail("wrong END name", log(g))
expect_fail("truncated log", log(good())[:-40])
print("PASS verifier negative tests (synthetic logs; verifier fails closed on empty, missing, duplicate, truncated, crash, wrong API)")
