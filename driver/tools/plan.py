#!/usr/bin/env python3
"""Decide what one lane run does, from the workflow's inputs or from request files.

A run is asked for in one of two ways:
  * workflow_dispatch inputs (suite, scenario, ref, config, strict), or
  * a pushed commit that adds or changes docs/driver-requests/*.json. A request is
    {"suite": "smoke.json repro-*.json", "scenarios": [{...}, ...], "ref": "branch-or-sha",
     "config": "release", "strict": false}; every key is optional.
    (Requests live under docs/ because a docs-only push starts no other workflow.)

Writes inline scenarios to driver-inline/ and prints key=value lines for GITHUB_OUTPUT:
list, config, strict, ref.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REQUESTS = "docs/driver-requests"


def changed_requests():
    try:
        out = subprocess.run(["git", "show", "--name-only", "--diff-filter=AM", "--pretty=format:",
                              "HEAD", "--", REQUESTS], capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        return []
    return [line for line in out.stdout.splitlines() if line.endswith(".json")]


def main():
    env = os.environ
    inline_dir = Path("driver-inline")
    inline_dir.mkdir(exist_ok=True)
    suite, scenarios = [], []
    ref, config, strict = "", "release", False

    if env.get("EVENT") == "workflow_dispatch":
        suite = env.get("SUITE", "").split()
        if env.get("INLINE", "").strip():
            data = json.loads(env["INLINE"])
            scenarios = data if isinstance(data, list) else [data]
        ref = env.get("REF_INPUT", "").strip()
        config = env.get("CONFIG_INPUT") or "release"
        strict = env.get("STRICT_INPUT", "") == "true"
    else:
        requests = changed_requests()
        for path in requests:
            request = json.loads(Path(path).read_text())
            suite += str(request.get("suite", "")).split()
            scenarios += request.get("scenarios", [])
            ref = ref or str(request.get("ref", "")).strip()
            config = request.get("config", config)
            strict = strict or bool(request.get("strict", False))
            print(f"request {path}: {request.get('note', '')}", file=sys.stderr)
        if not requests:
            suite = ["smoke.json"]

    names = []
    for index, scenario in enumerate(scenarios):
        name = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(scenario.get("name", index))).strip("-")
        path = inline_dir / f"{name or index}.json"
        path.write_text(json.dumps(scenario, indent=1) + "\n")
        names.append(str(path))
    if not re.fullmatch(r"[A-Za-z0-9_./-]*", ref):
        sys.exit(f"refusing ref {ref!r}")
    if config not in ("release", "debug"):
        sys.exit(f"unknown config {config!r}")
    for item in suite:
        if not re.fullmatch(r"[A-Za-z0-9_.*?\[\]/-]+", item):
            sys.exit(f"refusing suite entry {item!r}")
    print("list=" + " ".join(suite + names))
    print("config=" + config)
    print("strict=" + ("1" if strict else ""))
    print("ref=" + ref)


if __name__ == "__main__":
    main()
