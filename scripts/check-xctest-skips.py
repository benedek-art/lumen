#!/usr/bin/env python3
"""Fail a test log that skipped a test the allowlist does not name.

    python3 scripts/check-xctest-skips.py <test log> [allowlist]

A skipped XCTest reads as green. This lists every skipped test in the log and exits 1
when one is not in the allowlist (default .github/expected-skips.txt), or when the
XCTest summary counts more skips than the log names or the allowlist holds.

Reads both formats:
  Apple XCTest (macOS):   Test Case '-[Module.Class method]' skipped (0.001 seconds).
  swift-corelibs-xctest:  Test Case 'Class.method' skipped (0.001 seconds)
"""
import os
import re
import sys

APPLE = re.compile(r"Test Case '-\[(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' skipped")
CORELIBS = re.compile(r"Test Case '([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)' skipped")
SUMMARY = re.compile(r"Executed [0-9]+ tests?, with ([0-9]+) tests? skipped")


def skipped_in(text):
    names = set()
    for pattern in (APPLE, CORELIBS):
        for match in pattern.finditer(text):
            names.add(match.group(1) + "." + match.group(2))
    # The outermost suite's summary is the largest count in the log.
    counts = [int(m.group(1)) for m in SUMMARY.finditer(text)]
    return names, max(counts, default=0)


def allowlist(path):
    with open(path) as handle:
        lines = (line.split("#", 1)[0].strip() for line in handle)
        return {line for line in lines if line}


def problems(names, counted, allowed):
    found = []
    for name in sorted(names - allowed):
        found.append(f"unexpected skip: {name}")
    if counted > len(names):
        found.append(f"the summary counts {counted} skipped tests but the log names {len(names)}")
    if counted > len(allowed):
        found.append(f"{counted} skipped tests exceed the {len(allowed)} the allowlist permits")
    return found


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    allowed_path = argv[2] if len(argv) == 3 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", ".github", "expected-skips.txt")
    with open(argv[1], errors="replace") as handle:
        names, counted = skipped_in(handle.read())
    allowed = allowlist(allowed_path)
    print(f"=== skipped tests: {len(names)} named, {counted} counted by XCTest ===")
    for name in sorted(names):
        print(("  allowed    " if name in allowed else "  UNEXPECTED ") + name)
    found = problems(names, counted, allowed)
    for line in found:
        print(f"::error::{line}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
