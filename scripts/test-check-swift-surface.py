#!/usr/bin/env python3
"""Fixture suite for check-swift-surface.py — the guard on the guard.

docs/31's postscript records why this exists: the checker shipped a FALSE NEGATIVE —
a `help:` passed before `step:` at a `LumenSlider` call site sailed under "2797 call
sites match a declared initializer" — and a silent hole in a checker is worse than no
checker, because the count reads as confidence either way. (The postscript blamed a
multi-line ternary confusing `split_top`; the measured truth was larger: `LumenSlider`
declares no explicit `init`, Swift builds it a memberwise one, and the checker knew
only explicit ones — so 170 of the app layer's 195 types had NO checked call sites.)

Each fixture is a miniature package tree. The runner copies it to a temp dir together
with the real checker, runs the checker there, and asserts BOTH the exit code and — for
known-bad fixtures — that the output names the planted defect, so a fixture cannot
"fail" for an unrelated reason and read as caught.

    python3 scripts/test-check-swift-surface.py            # 0 if every fixture behaves
    python3 scripts/test-check-swift-surface.py --checker other.py   # judge another copy

Fixture layout: scripts/check-swift-surface-fixtures/<case>/
    expect.txt      first line CLEAN or FLAGGED; remaining lines are substrings the
                    checker's output must contain (for FLAGGED: the planted defect)
    Sources/...     the Swift tree the checker is pointed at

Fixtures live under scripts/ deliberately: the real checker globs Sources/ and Tests/
only, so the planted defects can never leak into a real run, and SwiftPM never sees
them either.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "check-swift-surface-fixtures"


def run_case(case: Path, checker: Path) -> list[str]:
    """Empty list if the case behaves; otherwise the complaints."""
    expect_file = case / "expect.txt"
    if not expect_file.exists():
        return [f"{case.name}: no expect.txt"]
    lines = expect_file.read_text().splitlines()
    verdict, needles = lines[0].strip(), [l for l in lines[1:] if l.strip()]
    if verdict not in ("CLEAN", "FLAGGED"):
        return [f"{case.name}: expect.txt must open with CLEAN or FLAGGED"]

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Package.swift").write_text("// fixture stub — never built\n")
        (root / "scripts").mkdir()
        shutil.copy2(checker, root / "scripts" / "check-swift-surface.py")
        for sub in ("Sources", "Tests"):
            if (case / sub).exists():
                shutil.copytree(case / sub, root / sub)
        proc = subprocess.run(
            [sys.executable, str(root / "scripts" / "check-swift-surface.py")],
            capture_output=True, text=True)
        out = proc.stdout + proc.stderr

    complaints = []
    flagged = proc.returncode != 0
    if verdict == "CLEAN" and flagged:
        complaints.append(f"{case.name}: expected CLEAN, checker flagged:\n{out}")
    if verdict == "FLAGGED" and not flagged:
        complaints.append(f"{case.name}: KNOWN-BAD PASSED THE CHECKER — the hole is "
                          f"open again:\n{out}")
    for needle in needles:
        if needle not in out:
            complaints.append(f"{case.name}: output does not name the planted defect "
                              f"({needle!r}):\n{out}")
    return complaints


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--checker", type=Path,
                    default=HERE / "check-swift-surface.py",
                    help="checker copy to judge (default: the real one)")
    args = ap.parse_args()
    if not args.checker.exists():
        print(f"no checker at {args.checker}")
        return 2
    cases = sorted(p for p in FIXTURES.iterdir() if p.is_dir())
    if not cases:
        print(f"no fixtures under {FIXTURES}")
        return 2

    failures = []
    for case in cases:
        complaints = run_case(case, args.checker)
        status = "ok " if not complaints else "FAIL"
        print(f"  {status}  {case.name}")
        failures.extend(complaints)

    if failures:
        print(f"\n{len(failures)} fixture expectations violated:\n")
        for f in failures:
            print(f + "\n")
        return 1
    print(f"\nall {len(cases)} fixtures behave: the known-bad are caught by name, "
          f"the known-good stay silent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
