"""Fake `python -m lumen_denoise.infer FILES --out DIR --strength S` for the Mac app tests.

Writes a small dummy "<stem>-Denoised.dng" per input into --out and prints one JSON line per file, like the
real engine. Env knobs:
  FAKE_SLEEP=sec         seconds per file (default 0)
  FAKE_FAIL_ON=substr    raise for the first input whose name contains substr (aborts the run, like the real engine)
  FAKE_SPLIT_JSON=1      write each JSON line in two flushed halves with a short sleep in between
  FAKE_SPAWN_CHILD=1     spawn a long `sleep 60` child that inherits stdout/stderr (logs "child pid N" on stderr)
  FAKE_NOISE=1           print non-JSON stdout lines and stderr chatter
  FAKE_IGNORE_TERM=1     ignore SIGTERM (tests the SIGKILL escalation)
  FAKE_NAN=1             print "K": NaN and "read_sd": Infinity (json.dumps does that for odd noise estimates)
  FAKE_TMPFILE=1         create a tempfile.mkdtemp() dir per input (logs "tmp dir PATH" on stderr), like DNG Converter
"""
import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--strength", type=float, default=1.0)
    a = ap.parse_args()
    env = os.environ
    delay = float(env.get("FAKE_SLEEP", "0"))
    fail_on = env.get("FAKE_FAIL_ON", "")
    noise = env.get("FAKE_NOISE") == "1"
    if env.get("FAKE_IGNORE_TERM") == "1":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if env.get("FAKE_SPAWN_CHILD") == "1":
        child = subprocess.Popen(["sleep", "60"])
        print(f"child pid {child.pid}", file=sys.stderr, flush=True)
    if noise:
        print("Loading model (fake)...", flush=True)
        print("warning: fake stderr chatter", file=sys.stderr, flush=True)
    os.makedirs(a.out, exist_ok=True)
    for f in a.files:
        t0 = time.time()
        stem = os.path.splitext(os.path.basename(f))[0]
        out = os.path.join(a.out, f"{stem}-Denoised.dng")
        if env.get("FAKE_TMPFILE") == "1":
            tmp = tempfile.mkdtemp()
            with open(os.path.join(tmp, "partial.dng"), "wb") as fh:
                fh.write(b"partial")
            print(f"tmp dir {tmp}", file=sys.stderr, flush=True)
        with open(out, "wb") as fh:   # written directly, not atomically, like the real engine
            fh.write(b"II*\x00fake-dng ")
            fh.flush()
            if delay:
                time.sleep(delay)
            if fail_on and fail_on in os.path.basename(f):
                raise RuntimeError(f"fake failure on {os.path.basename(f)}")
            fh.write(f"strength={a.strength}\n".encode())
        if noise:
            print(f"progress: {stem} 100%", flush=True)
            print(f"[fake] tile pass done for {stem}", file=sys.stderr, flush=True)
        nan = env.get("FAKE_NAN") == "1"
        line = json.dumps({"file": f, "out": out, "iso": 3200.0, "model": "ILCE-7M4",   # the real engine prints a float
                           "K": float("nan") if nan else 1.5, "read_sd": float("inf") if nan else 2.0,
                           "denoise_s": round(delay, 3), "total_s": round(time.time() - t0, 3)})
        if env.get("FAKE_SPLIT_JSON") == "1":
            half = len(line) // 2
            sys.stdout.write(line[:half]); sys.stdout.flush()
            time.sleep(0.2)
            sys.stdout.write(line[half:] + "\n"); sys.stdout.flush()
        else:
            print(line, flush=True)


if __name__ == "__main__":
    main()
