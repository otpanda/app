#!/usr/bin/env python3
import importlib.util, os
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("e", os.path.join(here, "extract-instrument.py")); e = importlib.util.module_from_spec(spec); spec.loader.exec_module(e)
ok = "FIXTURE api=34 ok a\nINSTRUMENTATION_STATUS_CODE: 0\nFIXTURE api=34 END phase=x oks=1\nINSTRUMENTATION_STATUS_CODE: 0\nINSTRUMENTATION_CODE: -1\n"
assert e.extract(ok, 34) == ["FIXTURE api=34 ok a", "FIXTURE api=34 END phase=x oks=1"]
assert e.extract(ok.replace("-1", "1"), 34)[-1].endswith("code ['1']")
assert "missing" in e.extract("FIXTURE api=34 ok a\n", 34)[-1]
assert "missing" in e.extract("", 34)[-1]
assert "INSTRUMENTATION_FAILED: x" in e.extract("INSTRUMENTATION_FAILED: x\n", 34)
assert e.extract("INSTRUMENTATION_STATUS: stream=FIXTURE api=34 ok a\nINSTRUMENTATION_CODE: -1\n", 34) == ["FIXTURE api=34 ok a"]
assert e.extract(ok + "INSTRUMENTATION_CODE: -1\n", 34)[-1].endswith("code ['-1', '-1']")
print("PASS instrument-output extractor negative tests (synthetic text only)")
