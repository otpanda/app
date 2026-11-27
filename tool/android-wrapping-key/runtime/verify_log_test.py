import importlib.util, unittest, re, os
spec = importlib.util.spec_from_file_location("v", os.path.join(os.path.dirname(__file__), "verify-log.py")); v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
EXTRA = {"env": ["env fingerprint=x"], "race-procs": ["ok exactly one process created the key"], "alias-lost": ["ok read with blob but no alias -> MISSING_ALIAS"], "corrupt": ["ok flipped tag byte -> CORRUPT"]}
def good(api=34):
    out = []
    for p in v.PHASES:
        out.append(f"== phase {p}"); n = v.MIN_OKS[p]
        extra = EXTRA.get(p, []); oks = [e for e in extra if e.startswith("ok ")]
        for e in extra:
            out.append(f"FIXTURE api={api} {e}")
        for i in range(n - len(oks)): out.append(f"FIXTURE api={api} ok filler {i}")
        out.append(f"FIXTURE api={api} END phase={p} oks={n}")
    return "\n".join(out) + "\n"
class T(unittest.TestCase):
    def test_good(self): self.assertEqual(v.verify(good(), "34"), [])
    def test_empty(self): self.assertTrue(v.verify("", "34"))
    def test_wrong_api(self): self.assertTrue(v.verify(good(33), "34"))
    def test_missing_phase(self): self.assertTrue(v.verify(good().replace("== phase delete", "== phase gone"), "34"))
    def test_fail_line(self): self.assertTrue(v.verify(good().replace("ok filler 0", "FAIL x", 1), "34"))
    def test_wrong_kind(self): self.assertTrue(v.verify(good().replace("-> MISSING_ALIAS", "-> MISSING_ALIAS (got CORRUPT)"), "34"))
    def test_truncated(self): self.assertTrue(v.verify(good().rsplit("FIXTURE", 1)[0], "34"))
    def test_low_oks(self): self.assertTrue(v.verify(good().replace("oks=7", "oks=3", 1), "34"))
if __name__ == "__main__": unittest.main()
