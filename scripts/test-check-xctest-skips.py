#!/usr/bin/env python3
"""Checks on check-xctest-skips.py, and on the committed allowlist it reads.

The corelibs log below is real `swift test` output from Swift 6.1.2 on Linux (path
shortened). The Apple log is Apple XCTest's documented `-[Module.Class method]` form,
which only a macOS runner prints.

    python3 scripts/test-check-xctest-skips.py      # exit 0 when every case holds
"""
import importlib.util, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "check-xctest-skips.py")
spec = importlib.util.spec_from_file_location("check_xctest_skips", SCRIPT)
skips = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skips)

failures = []


def check(label, condition):
    print(("ok   " if condition else "FAIL ") + label)
    if not condition:
        failures.append(label)


CORELIBS_LOG = """\
Test Suite 'SpeedBenchTests' started at 2026-10-20 03:52:35.587
Test Case 'SpeedBenchTests.testInteractiveCPUPath' started at 2026-10-20 03:52:35.587
Tests/LumenCoreTests/SpeedBenchTests.swift:24: SpeedBenchTests.testInteractiveCPUPath : Test skipped: required false value but got true - set LUMEN_BENCH=1
Test Case 'SpeedBenchTests.testInteractiveCPUPath' skipped (0.001 seconds)
Test Suite 'SpeedBenchTests' passed at 2026-10-20 03:52:35.588
\t Executed 1 test, with 1 test skipped and 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'Selected tests' passed at 2026-10-20 03:52:35.588
\t Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.002 (0.002) seconds
"""

APPLE_LOG = """\
Test Case '-[LumenCoreTests.SpeedBenchTests testInteractiveCPUPath]' started.
Tests/LumenCoreTests/SpeedBenchTests.swift:24: -[LumenCoreTests.SpeedBenchTests testInteractiveCPUPath] : Test skipped - set LUMEN_BENCH=1
Test Case '-[LumenCoreTests.SpeedBenchTests testInteractiveCPUPath]' skipped (0.001 seconds).
Test Case '-[LumenPipelineTests.KernelGoldenTests testEveryKernelCompiles]' started.
Test Case '-[LumenPipelineTests.KernelGoldenTests testEveryKernelCompiles]' passed (0.120 seconds).
Test Suite 'All tests' passed at 2026-10-20 03:52:35.588.
\t Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.121 (0.130) seconds
"""

UNEXPECTED_LINE = ("Test Case '-[LumenPipelineTests.KernelGoldenTests "
                   "testGraphMatchesTheReferenceRendererOnTheColourPath]' skipped (0.002 seconds).\n")

allowed = skips.allowlist(os.path.join(ROOT, ".github", "expected-skips.txt"))

for label, log in (("corelibs", CORELIBS_LOG), ("apple", APPLE_LOG)):
    names, counted = skips.skipped_in(log)
    check(f"{label}: the skipped test is named", names == {"SpeedBenchTests.testInteractiveCPUPath"})
    check(f"{label}: the summary count is read", counted == 1)
    check(f"{label}: an allowlisted skip passes", skips.problems(names, counted, allowed) == [])

names, counted = skips.skipped_in(APPLE_LOG + UNEXPECTED_LINE)
found = skips.problems(names, counted, allowed)
check("a skip outside the allowlist is reported by name",
      any("KernelGoldenTests.testGraphMatchesTheReferenceRendererOnTheColourPath" in f for f in found))

# A skip XCTest counts but the log does not name (a format this parser misses).
names, counted = skips.skipped_in(APPLE_LOG.replace("with 1 test skipped", "with 2 tests skipped"))
check("a counted but unnamed skip fails", skips.problems(names, counted, allowed) != [])

check("more skips than the allowlist holds fails",
      skips.problems(set(), len(allowed) + 1, allowed) != [])

# The command line: exit status is what the workflows read.
with tempfile.TemporaryDirectory() as d:
    good, bad = os.path.join(d, "good.log"), os.path.join(d, "bad.log")
    open(good, "w").write(APPLE_LOG)
    open(bad, "w").write(APPLE_LOG + UNEXPECTED_LINE)
    run = lambda path: subprocess.run([sys.executable, SCRIPT, path], capture_output=True).returncode
    check("the command exits 0 on allowlisted skips", run(good) == 0)
    check("the command exits 1 on an unexpected skip", run(bad) == 1)

# Every allowlist entry must still name a test, so a rename cannot leave a stale
# entry that would wave through a different test later given the same name.
sources = {}
for directory, _, files in os.walk(os.path.join(ROOT, "Tests")):
    for name in files:
        if name.endswith(".swift"):
            sources[os.path.join(directory, name)] = open(os.path.join(directory, name)).read()
for entry in sorted(allowed):
    cls, method = entry.split(".")
    exists = any(re.search(rf"\bclass {cls}\b", text) and re.search(rf"\bfunc {method}\(", text)
                 for text in sources.values())
    check(f"allowlist entry {entry} names a test that exists", exists)

if failures:
    print(f"{len(failures)} case(s) failed")
    sys.exit(1)
print("all cases hold")
