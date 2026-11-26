#!/usr/bin/env python3
"""Ask the Driver lane for a run by pushing a request commit.

    request.py --scenario my-scenario.json --ref <branch under test> --wait
    request.py --suite "smoke.json repro-*.json" --wait

The lane starts on any push that adds docs/driver-requests/<name>.json. This adds
that file on top of the shared requests branch (--queue, default
claude/loving-cray-d58nrb-driver) and pushes; if someone else pushed first it starts
over on the new tip. It never touches your working tree or your branch.

Why one shared branch: a push that only touches docs/ starts the Driver lane and no
other workflow, and GitHub scopes build caches to the branch, so every request on that
branch reuses the app already built for the same sources.

What runs: the driver, tools and committed scenarios on the requests branch; your
--scenario files, sent inline; the app code named by --ref (default: the requests
branch itself, which carries a copy of the driver branch's app).

Prints the request commit's SHA: the run is the Driver run whose head_sha is that
commit. With --wait it then waits and prints the results (results.py).

--base/--branch push a one-off request built on any commit instead (for testing a
change to the driver itself). The commit must already be on the remote, and the branch
should be a new one: pushed onto an existing branch, the commit is compared with that
branch's old tip and can start every other workflow too.
"""
import argparse
import json
import os
import re
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


def resolve_ref(ref, remote):
    """A branch, tag or SHA (short or full) as the full 40-character commit SHA, so the
    run tests exactly the commit meant now, and the lane can fetch it."""
    if not ref or re.fullmatch(r"[0-9a-f]{40}", ref):
        return ref
    name = ref[len("origin/"):] if ref.startswith("origin/") else ref
    listed = subprocess.run(["git", "ls-remote", remote, f"refs/heads/{name}", f"refs/tags/{name}",
                             f"refs/tags/{name}^{{}}"], capture_output=True, text=True)
    if listed.returncode == 0 and listed.stdout.strip():
        lines = listed.stdout.strip().splitlines()
        # An annotated tag lists its object and then the commit it points at (^{}).
        peeled = [line for line in lines if line.endswith("^{}")]
        return (peeled or lines)[0].split()[0]
    if re.fullmatch(r"[0-9a-f]{4,39}", ref):
        local = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                               capture_output=True, text=True)
        if local.returncode == 0 and local.stdout.strip():
            return local.stdout.strip()
        repo = os.environ.get("DRIVER_REPO", "benedek-art/lumen")
        api = subprocess.run(["curl", "-sS", "--fail", "-m", "30",
                              f"https://api.github.com/repos/{repo}/commits/{ref}"],
                             capture_output=True, text=True)
        if api.returncode == 0:
            try:
                return json.loads(api.stdout)["sha"]
            except (ValueError, KeyError):
                pass
    sys.exit(f"--ref {ref}: no such branch, tag or commit on {remote} (fetch it, or give a "
             "longer SHA)")


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
    parser.add_argument("--queue", default="claude/loving-cray-d58nrb-driver",
                        help="the shared requests branch")
    parser.add_argument("--base", default="",
                        help="one-off: build the request on this commit instead of the queue")
    parser.add_argument("--branch", default="", help="one-off: push to this (new) branch")
    parser.add_argument("--force", action="store_true", help="one-off: force-push")
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--dry-run", action="store_true", help="create the commit, do not push")
    parser.add_argument("--wait", action="store_true",
                        help="then wait for the run and print its results (results.py)")
    parser.add_argument("--out", default="", help="with --wait: where to unpack the artifact")
    args = parser.parse_args()

    scenarios = []
    for path in args.scenario:
        data = json.loads(Path(path).read_text())
        scenarios += data if isinstance(data, list) else [data]
    if not args.suite and not scenarios:
        sys.exit("nothing to run: give --suite and/or --scenario")
    ref = resolve_ref(args.ref, args.remote)
    if ref != args.ref:
        print(f"--ref {args.ref} is {ref}", file=sys.stderr)
    name = args.name or time.strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(3).hex()
    if not all(c.isalnum() or c in "-_." for c in name):
        sys.exit("--name takes letters, digits, - _ . only")
    request = {"suite": args.suite, "scenarios": scenarios, "ref": ref,
               "config": args.config, "strict": args.strict, "note": args.note}
    if ref != args.ref:
        request["refName"] = args.ref
    blob = git("hash-object", "-w", "--stdin", stdin=json.dumps(request, indent=1) + "\n")
    message = f"Driver request: {name}\n"
    if args.note:
        message += f"\n{args.note}\n"
    if ref:
        message += f"\nTesting {args.ref}" + (f" ({ref})" if ref != args.ref else "") + "\n"
    trailers = os.environ.get("DRIVER_COMMIT_TRAILERS", "").strip()
    if trailers:
        message += f"\n{trailers}\n"

    def commit_on(base):
        with tempfile.TemporaryDirectory() as scratch:
            index = {"GIT_INDEX_FILE": str(Path(scratch) / "index")}
            git("read-tree", base, env=index)
            git("update-index", "--add", "--cacheinfo",
                f"100644,{blob},docs/driver-requests/{name}.json", env=index)
            tree = git("write-tree", env=index)
        return git("commit-tree", tree, "-p", base, "-m", message)

    one_off = bool(args.base or args.branch)
    commit = ""
    for attempt in range(8):
        if one_off:
            base = git("rev-parse", args.base or "HEAD")
            branch = args.branch or f"claude/loving-cray-d58nrb-run-{name}"
            if not git("branch", "-r", "--contains", base) and not args.force:
                sys.exit(f"{base[:10]} is not on the remote yet. Push it first: a request "
                         "push that carries code starts every workflow.")
        else:
            branch = args.queue
            git("fetch", "--quiet", args.remote, branch)
            base = git("rev-parse", "FETCH_HEAD")
        commit = commit_on(base)
        if args.dry_run:
            print(commit)
            return
        push = ["git", "push", "--quiet", args.remote, f"{commit}:refs/heads/{branch}"]
        if args.force and one_off:
            push.insert(2, "--force")
        out = subprocess.run(push, capture_output=True, text=True)
        if out.returncode == 0:
            break
        if one_off and "rejected" in out.stderr:
            sys.exit(f"push failed: {out.stderr.strip()}")
        if attempt == 7:
            sys.exit(f"push failed after 8 tries: {out.stderr.strip()}")
        time.sleep(1 + attempt)  # another tester got there first, or the network blinked
    print(commit, flush=True)
    if args.wait:
        command = [sys.executable, str(Path(__file__).resolve().parent / "results.py"), commit]
        if args.out:
            command += ["--out", args.out]
        sys.exit(subprocess.run(command).returncode)


if __name__ == "__main__":
    main()
