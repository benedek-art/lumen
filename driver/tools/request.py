#!/usr/bin/env python3
"""Ask the Driver lane for a run by pushing a request commit.

    request.py --suite "smoke.json repro-*.json"
    request.py --scenario my-scenario.json --scenario other.json --ref some-branch
    request.py --suite smoke.json --branch claude/loving-cray-d58nrb-driver --force

The lane starts on any push that adds docs/driver-requests/<name>.json (a docs-only
push starts no other workflow). This writes that file in a commit on top of --base
(default HEAD) without touching the working tree, and pushes it to --branch (default:
the current branch). The driver, its tools and the scenario files named by --suite are
the ones in that commit; --ref names the app code to test when it is another branch.

Prints the commit SHA: the run is the Driver run whose head_sha is that commit.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def git(*args, env=None, stdin=None):
    out = subprocess.run(["git", *args], capture_output=True, text=True, input=stdin,
                         env={**os.environ, **(env or {})})
    if out.returncode != 0:
        sys.exit(f"git {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--suite", default="", help="scenario files or globs under driver/scenarios")
    parser.add_argument("--scenario", action="append", default=[],
                        help="a scenario JSON file to send inline (repeatable); it need not be committed")
    parser.add_argument("--ref", default="", help="branch, tag or SHA of the app to test (default: the request commit)")
    parser.add_argument("--config", default="release", choices=["release", "debug"])
    parser.add_argument("--strict", action="store_true", help="fail the job on a failed expectation")
    parser.add_argument("--name", default="", help="request name (default: a timestamp)")
    parser.add_argument("--note", default="")
    parser.add_argument("--base", default="HEAD", help="commit the request is added on top of")
    parser.add_argument("--branch", default="", help="branch to push to (default: the current branch)")
    parser.add_argument("--force", action="store_true", help="force-push (for a throwaway queue branch)")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--dry-run", action="store_true", help="create the commit, do not push")
    args = parser.parse_args()

    scenarios = []
    for path in args.scenario:
        data = json.loads(Path(path).read_text())
        scenarios += data if isinstance(data, list) else [data]
    if not args.suite and not scenarios:
        sys.exit("nothing to run: give --suite and/or --scenario")
    name = args.name or time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"
    request = {"suite": args.suite, "scenarios": scenarios, "ref": args.ref,
               "config": args.config, "strict": args.strict, "note": args.note}
    branch = args.branch or git("rev-parse", "--abbrev-ref", "HEAD")
    base = git("rev-parse", args.base)

    blob = git("hash-object", "-w", "--stdin", stdin=json.dumps(request, indent=1) + "\n")
    with tempfile.TemporaryDirectory() as scratch:
        index = {"GIT_INDEX_FILE": str(Path(scratch) / "index")}
        git("read-tree", base, env=index)
        git("update-index", "--add", "--cacheinfo", f"100644,{blob},docs/driver-requests/{name}.json",
            env=index)
        tree = git("write-tree", env=index)
    message = f"Driver request: {name}\n"
    if args.note:
        message += f"\n{args.note}\n"
    trailers = os.environ.get("DRIVER_COMMIT_TRAILERS", "").strip()
    if trailers:
        message += f"\n{trailers}\n"
    commit = git("commit-tree", tree, "-p", base, "-m", message)
    if args.dry_run:
        print(commit)
        return
    push = ["push", args.remote, f"{commit}:refs/heads/{branch}"]
    if args.force:
        push.insert(1, "--force")
    for attempt in range(4):
        out = subprocess.run(["git", *push], capture_output=True, text=True)
        if out.returncode == 0:
            break
        if "rejected" in out.stderr or attempt == 3:
            sys.exit(f"push failed: {out.stderr.strip()}")
        time.sleep(2 ** (attempt + 1))
    current = git("rev-parse", "--abbrev-ref", "HEAD")
    if current == branch and git("rev-parse", "HEAD") == base:
        git("merge", "--ff-only", commit)
    print(commit)


if __name__ == "__main__":
    main()
