#!/usr/bin/env python3
"""Print the per-scenario verdict table for a driver output directory.

    summarize.py OUT_DIR

Reads OUT_DIR/<scenario>/{report.json,exit.txt,witness.json}; writes summary.md and
summary.json beside them. Standard library only.
"""
import json
import sys
from pathlib import Path

EXIT = {0: "PASS", 1: "FAIL", 2: "ERROR", 3: "HANG", 4: "TIMEOUT", 124: "KILLED"}


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def one(directory):
    report = load(directory / "report.json") or {}
    witness = load(directory / "witness.json") or {}
    try:
        code = int((directory / "exit.txt").read_text().strip())
    except (OSError, ValueError):
        code = None
    verdict = EXIT.get(code, "CRASH" if code is not None and code >= 128 else "NO-EXIT")
    if not report:
        verdict = verdict if verdict not in ("PASS", "FAIL") else "NO-REPORT"
    steps = report.get("steps", [])
    failing = [s for s in steps if s.get("status") == "fail"]
    errors = [s for s in steps if s.get("status") == "error"]
    checks = witness.get("checks", [])
    witness_failed = [c for c in checks if not c.get("pass")]
    if verdict == "PASS" and witness_failed:
        verdict = "FAIL"
    notes = []
    if report.get("setupError"):
        notes.append("setup: " + report["setupError"])
    for s in errors[:2]:
        notes.append(f"step {s.get('i')} {s.get('do')}: {s.get('error')}")
    for s in failing[:3]:
        notes.append(f"{s.get('check')} (was {s.get('actual')})")
    for c in witness_failed[:3]:
        notes.append(f"witness {c.get('check')} (was {c.get('actual')})")
    expect = report.get("expect", {})
    passed = expect.get("pass", 0) + sum(1 for c in checks if c.get("pass"))
    total = passed + expect.get("fail", 0) + len(witness_failed)
    return {
        "name": directory.name, "verdict": verdict, "exit": code,
        "passed": passed, "checks": total, "errors": len(errors) + bool(report.get("setupError")),
        "seconds": round(report.get("seconds", 0), 1), "notes": notes,
        "failing": [{"check": s.get("check"), "actual": s.get("actual"), "note": s.get("note")}
                    for s in failing]
                   + [{"check": "witness " + str(c.get("check")), "actual": c.get("actual")}
                      for c in witness_failed],
    }


def main():
    out = Path(sys.argv[1])
    rows = [one(d) for d in sorted(out.iterdir()) if (d / "scenario.json").exists()]
    (out / "summary.json").write_text(json.dumps(rows, indent=1) + "\n")
    width = max([len(r["name"]) for r in rows] + [8])
    print(f"{'SCENARIO':<{width}}  VERDICT    CHECKS  ERR  SECONDS  FIRST PROBLEM")
    for r in rows:
        first = r["notes"][0] if r["notes"] else ""
        print(f"{r['name']:<{width}}  {r['verdict']:<9}  {r['passed']:>2}/{r['checks']:<3}  "
              f"{r['errors']:>3}  {r['seconds']:>7}  {first[:110]}")
    lines = ["| scenario | verdict | checks | errors | s | problems |", "|---|---|---|---|---|---|"]
    for r in rows:
        problems = "<br>".join(n.replace("|", "\\|")[:200] for n in r["notes"]) or " "
        lines.append(f"| {r['name']} | {r['verdict']} | {r['passed']}/{r['checks']} | "
                     f"{r['errors']} | {r['seconds']} | {problems} |")
    (out / "summary.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
