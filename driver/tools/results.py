#!/usr/bin/env python3
"""Wait for a Driver run, fetch its artifact and print what happened.

    results.py SOURCE [--out DIR] [--scenario NAME] [--steps] [--timeout SECONDS]

SOURCE is one of
  * a request commit's SHA (what request.py prints) or a run id: waits for the run to
    finish, then downloads its artifact through the GitHub REST API with curl;
  * the artifact's signed download URL, a downloaded .zip, or an unpacked directory.

Prints the verdict table, then for each scenario its failed checks (with the step's
note), driver errors, the numbers each gesture step measured and where the screenshots
are. --steps lists every step. Exit status: 0 when every scenario passed, 1 otherwise.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import summarize  # noqa: E402

REPO = os.environ.get("DRIVER_REPO", "benedek-art/lumen")
API = f"https://api.github.com/repos/{REPO}"


def api(path):
    out = subprocess.run(["curl", "-sS", "--fail", "-m", "30", API + path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"GET {path}: {out.stderr.strip()}")
    return json.loads(out.stdout)


def run_for(source, timeout):
    """The finished run for a commit SHA or run id. Polls every 30 s."""
    deadline = time.time() + timeout
    run = None
    while True:
        try:
            if re.fullmatch(r"[0-9a-f]{7,40}", source) and not source.isdigit():
                runs = api(f"/actions/workflows/driver.yml/runs?head_sha={source}&per_page=5")
                run = (runs.get("workflow_runs") or [None])[0]
            else:
                run = api(f"/actions/runs/{source}")
        except (RuntimeError, ValueError) as error:
            print(f"  ({error})", file=sys.stderr)
        if run and run.get("status") == "completed":
            return run
        if time.time() > deadline:
            sys.exit(f"run not finished after {timeout} s: {run and run.get('html_url')}")
        state = run.get("status") if run else "not started"
        print(f"  waiting: {state}", file=sys.stderr)
        time.sleep(30)


def fetch_run(source, out, timeout):
    run = run_for(source, timeout)
    print(f"run {run['id']} {run.get('conclusion')}  {run.get('html_url')}")
    artifacts = api(f"/actions/runs/{run['id']}/artifacts").get("artifacts", [])
    if not artifacts:
        sys.exit("the run uploaded no artifact; read its log: "
                 f"get_job_logs for run {run['id']}")
    out.mkdir(parents=True, exist_ok=True)
    archive = out / "artifact.zip"
    subprocess.run(["curl", "-sS", "--fail", "-L", "-m", "300", "-o", str(archive),
                    f"{API}/actions/artifacts/{artifacts[0]['id']}/zip"], check=True)
    with zipfile.ZipFile(archive) as z:
        z.extractall(out)
    return out


GESTURE_KEYS = ("via", "events", "postingMs", "postLateMeanMs", "postLateWorstMs", "gestureMs", "framesDuring", "maxFrameGapMs", "firstFrameMs",
                "distinctValues", "distinctValuesShown", "staleFramesDuring",
                "releaseToFinalValueMs", "releaseToSharpMs", "releaseToSettledMs",
                "hitches", "hitchMaxMs", "hitchAfterMaxMs", "screenChangesDuring",
                "screenMaxGapMs", "screenFirstChangeMs", "screenLastChangeMs", "watchStart",
                "watchEnd")


def unpack(source, out, timeout):
    path = Path(source)
    if path.is_dir():
        return path
    if re.fullmatch(r"[0-9a-f]{7,40}|[0-9]+", source):
        return fetch_run(source, out, timeout)
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
    parser.add_argument("--timeout", type=int, default=2400)
    args = parser.parse_args()
    out = unpack(args.source, Path(args.out or tempfile.mkdtemp(prefix="driver-run-")),
                 args.timeout)
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
            if step.get("id") != f"s{step.get('i')}":
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
                if status == "ok" and not args.steps:
                    print(label + (f"  ({step['note']})" if step.get("note") else ""))
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
    if not rows:
        log = out / "build.log"
        if log.exists():
            errors = sorted({line.strip() for line in log.read_text(errors="replace").splitlines()
                             if "error:" in line})
            print("no scenario ran. Build errors:" if errors else "no scenario ran.")
            for line in errors[:40]:
                print("  " + line[-300:])
    sys.exit(0 if rows and all(r["verdict"] == "PASS" for r in rows) else 1)


if __name__ == "__main__":
    main()
