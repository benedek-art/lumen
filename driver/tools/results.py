#!/usr/bin/env python3
"""Unpack a Driver run's artifact and print what happened.

    results.py SOURCE [--out DIR] [--scenario NAME] [--steps]

SOURCE is the artifact's signed download URL, a downloaded .zip, or a directory that
is already unpacked. Prints the verdict table, then for each scenario its failed
checks (with the step's note), driver errors, the numbers each gesture step measured
and where the screenshots are. --steps lists every step.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import summarize  # noqa: E402

GESTURE_KEYS = ("via", "events", "gestureMs", "framesDuring", "maxFrameGapMs", "firstFrameMs",
                "distinctValues", "distinctValuesShown", "staleFramesDuring",
                "releaseToFinalValueMs", "releaseToSharpMs", "releaseToSettledMs",
                "hitches", "hitchMaxMs", "watchStart", "watchEnd")


def unpack(source, out):
    path = Path(source)
    if path.is_dir():
        return path
    out.mkdir(parents=True, exist_ok=True)
    if source.startswith("http"):
        archive = out / "artifact.zip"
        subprocess.run(["curl", "-sS", "--fail", "-L", "-o", str(archive), source], check=True)
    else:
        archive = path
    with zipfile.ZipFile(archive) as z:
        z.extractall(out)
    return out


def short(value):
    if isinstance(value, float):
        return round(value, 1)
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("--out", default="")
    parser.add_argument("--scenario", default="")
    parser.add_argument("--steps", action="store_true")
    args = parser.parse_args()
    out = unpack(args.source, Path(args.out or tempfile.mkdtemp(prefix="driver-run-")))
    rows = [summarize.one(d) for d in sorted(out.iterdir()) if (d / "scenario.json").exists()]
    print(f"results in {out}\n")
    width = max([len(r["name"]) for r in rows] + [8])
    print(f"{'SCENARIO':<{width}}  VERDICT    CHECKS  ERR  SECONDS")
    for r in rows:
        print(f"{r['name']:<{width}}  {r['verdict']:<9}  {r['passed']:>2}/{r['checks']:<3}  "
              f"{r['errors']:>3}  {r['seconds']:>7}")
    for r in rows:
        if args.scenario and r["name"] != args.scenario:
            continue
        directory = out / r["name"]
        report = summarize.load(directory / "report.json") or {}
        witness = summarize.load(directory / "witness.json") or {}
        machine = report.get("machine", {})
        print(f"\n== {r['name']}: {r['verdict']}  (exit {r['exit']})")
        if machine:
            print(f"   machine: {machine.get('model')} · {machine.get('chip')} · {machine.get('gpu')} · "
                  f"{machine.get('os')} · display {machine.get('displayWidth')}x"
                  f"{machine.get('displayHeight')}@{machine.get('displayScale')}x · build "
                  f"{str(report.get('build', ''))[:10]}")
        if report.get("setupError"):
            print(f"   SETUP ERROR: {report['setupError']}")
        for step in report.get("steps", []):
            status = step.get("status")
            label = f"   [{step.get('i'):>2}] {step.get('do')}"
            if step.get("id", "").startswith("s") is False:
                label += f" {step.get('id')}"
            if status == "error":
                print(f"{label}: ERROR {step.get('error')}")
            elif status == "fail":
                print(f"{label}: FAIL {step.get('check')} — was {short(step.get('actual'))}"
                      + (f"  ({step['note']})" if step.get("note") else ""))
            elif args.steps and status == "pass":
                print(f"{label}: pass {step.get('check')} — was {short(step.get('actual'))}")
            elif args.steps:
                print(f"{label}: {status}")
            if "gestureMs" in step and (args.steps or step.get("do") in ("drag", "pinch", "swipe")):
                numbers = {k: short(step[k]) for k in GESTURE_KEYS if k in step}
                if "latencyMs" in step:
                    numbers["latencyMs"] = {k: short(v) for k, v in step["latencyMs"].items()}
                print(f"        {json.dumps(numbers)}")
        for name, group in witness.get("groups", {}).items():
            print(f"   witness {name}: drift max {short(group.get('driftMaxPt'))} pt, end "
                  f"{short(group.get('driftEndPt'))} pt, jump {short(group.get('jumpMaxPt'))} pt, "
                  f"scale x{short(group.get('scaleRatio'))}, moved "
                  f"({short(group.get('moveX'))}, {short(group.get('moveY'))}) pt, "
                  f"{group.get('located')}/{group.get('captures')} located")
        for check in witness.get("checks", []):
            if args.steps or not check.get("pass"):
                print(f"   witness {'pass' if check.get('pass') else 'FAIL'} {check.get('check')} — was "
                      f"{short(check.get('actual'))}" + (f"  ({check['note']})" if check.get("note") else ""))
        for extra in ("watchdog.json", "watchdog-sample.txt", "outer-timeout-sample.txt"):
            if (directory / extra).exists():
                print(f"   see {directory / extra}")
        shots = sorted((directory / "shots").glob("*.png")) if (directory / "shots").exists() else []
        named = [s for s in shots if not s.stem[-3:].isdigit()]
        print(f"   {len(shots)} screenshots in {directory / 'shots'}"
              + (": " + ", ".join(s.name for s in named[:14]) if named else ""))


if __name__ == "__main__":
    main()
