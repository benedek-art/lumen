"""WS-16 TEST-1: every stage-level acceptance line is backed by an XCTest in Tests/LumenCoreTests
whose name contains WS16_<ID without the dash> (e.g. testWS16_SKIN4a_ProtectionHasNoHueSeam).
Run the tests themselves with:  swift test --filter WS16
Usage: python3 m_tests.py"""
import sys, os, re, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import check, summary, REPO

REQUIRED = ["HUE-1", "SAT-1", "SAT-2", "SAT-3a", "SAT-4", "SAT-5", "VIB-1", "VIB-2", "VIB-5a", "VIB-7",
            "SKIN-1", "SKIN-2", "SKIN-3", "SKIN-4a", "SKIN-5", "DEN-1a", "DEN-2", "DEN-4",
            "BW-1", "BW-2", "BW-3a", "BW-4", "BW-5", "BW-6a", "BW-7", "PAR-1", "ID-2"]
names = set()
for f in glob.glob(os.path.join(REPO, "Tests", "LumenCoreTests", "**", "*.swift"), recursive=True):
    names |= set(re.findall(r"func (test\w+)\s*\(", open(f).read()))
missing = [i for i in REQUIRED if not any(f"WS16_{i.replace('-', '')}" in n for n in names)]
check("TEST-1", not missing, f"{len(REQUIRED) - len(missing)}/{len(REQUIRED)} lines have a test; missing {missing}",
      "every listed line has a test named WS16_<ID>")
summary()
