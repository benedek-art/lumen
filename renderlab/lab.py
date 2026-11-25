#!/usr/bin/env python3
"""Render lab helper (stdlib only). See renderlab/README.md.

  lab.py wait <run_id>                      poll a render-lab run until it completes; list artifacts
  lab.py fetch <run_id> --url <signed-url>  download + unpack an artifact, print table and sheets
  lab.py open <zip-or-dir>                  unpack (if zip) and print table and sheet paths
  lab.py local <manifest.json>... [--plates DIR] [--out DIR] [--lut N] [--shard k/n]
                                            run the reference path in this container
  lab.py table <dir>                        print the results table of an output tree
  lab.py merge <out> <dir>...               merge output trees (CI shards) into one
  lab.py compress <dir>                     recompress stored-deflate PNGs written on Linux
"""

import json
import os
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import zipfile
import zlib
from pathlib import Path

REPO = "benedek-art/lumen"
ROOT = Path(__file__).resolve().parent.parent
MERGED = {"summary.tsv", "index.json", "run.json"}


def api(path):
    req = urllib.request.Request(f"https://api.github.com/repos/{REPO}/{path}",
                                 headers={"Accept": "application/vnd.github+json",
                                          "User-Agent": "lumen-renderlab"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def cmd_wait(args):
    run_id = args[0]
    while True:
        run = api(f"actions/runs/{run_id}")
        print(f"{time.strftime('%H:%M:%S')} run {run_id}: {run['status']} {run.get('conclusion') or ''}",
              flush=True)
        if run["status"] == "completed":
            break
        time.sleep(60)
    jobs = api(f"actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    for j in jobs:
        print(f"  job {j['name']}: {j.get('conclusion')}")
    arts = api(f"actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    print("artifacts (id, name, MB):")
    for a in arts:
        print(f"  {a['id']}  {a['name']}  {a['size_in_bytes'] / 1e6:.1f}")
    best = next((a for a in arts if a["name"] == "renderlab-report"), None)
    if best:
        print(f"\nNext: mcp__github__actions_get method=download_workflow_run_artifact "
              f"owner=benedek-art repo=lumen resource_id={best['id']}\n"
              f"then: python3 renderlab/lab.py fetch {run_id} --url '<the signed URL>'")
    return 0 if run.get("conclusion") == "success" else 1


def cmd_fetch(args):
    run_id = args[0]
    url = args[args.index("--url") + 1] if "--url" in args else None
    out = Path(args[args.index("--out") + 1]) if "--out" in args else Path(f"renderlab-runs/{run_id}")
    if not url:
        return cmd_wait([run_id])
    out.mkdir(parents=True, exist_ok=True)
    zpath = out / "artifact.zip"
    urllib.request.urlretrieve(url, zpath)
    return cmd_open([str(zpath)])


def cmd_open(args):
    p = Path(args[0])
    if p.suffix == ".zip":
        dest = p.with_suffix("")
        with zipfile.ZipFile(p) as z:
            for name in z.namelist():
                if name.startswith("/") or ".." in Path(name).parts:
                    raise SystemExit(f"unsafe path in zip: {name}")
            z.extractall(dest)
        p = dest
    return cmd_table([str(p)])


def rows_of(root):
    rows = []
    for f in sorted(Path(root).rglob("summary.tsv")):
        lines = f.read_text().splitlines()
        if not lines:
            continue
        head = lines[0].split("\t")
        for line in lines[1:]:
            cells = line.split("\t")
            row = dict(zip(head, cells))
            row["_base"] = f.parent
            if len(cells) < len(head):
                row["error"] = cells[-1]
            rows.append(row)
    return rows


def cmd_table(args):
    root = Path(args[0]).resolve()
    rows = rows_of(root)
    cols = ["job", "photo", "path", "label", "L_mean", "L_p50", "clip0", "clip255", "chroma",
            "dMAE", "dLuma", "dHue", "Yratio", "patchRatio", "ms"]
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    errors = 0
    for r in rows:
        if "error" in r:
            errors += 1
            print(f"| {r.get('job')} | {r.get('photo')} | {r.get('path')} | {r.get('label')} | {r['error']} |")
            continue
        print("| " + " | ".join(r.get(c, "-") for c in cols) + " |")
    sheets = sorted(root.rglob("sheets/*.png"))
    print(f"\n{len(rows)} renders, {errors} errors, {len(sheets)} sheets under {root}")
    for s in sheets:
        print(f"  sheet: {s}")
    for f in sorted(root.rglob("drift.tsv")):
        print(f"\ndrift table {f}:\n{f.read_text()}")
    return 1 if errors else 0


def cmd_merge(args):
    out = Path(args[0])
    acc = {}
    for src in args[1:]:
        src = Path(src)
        if not src.exists():
            continue
        for f in src.rglob("*"):
            if f.is_dir():
                continue
            rel = f.relative_to(src)
            dest = out / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            if f.name in MERGED:
                acc.setdefault(dest, []).append(f)
            else:
                shutil.copy2(f, dest)
    for dest, files in acc.items():
        if dest.name == "summary.tsv":
            head, body = None, []
            for f in files:
                lines = f.read_text().splitlines()
                head = head or lines[0]
                body += lines[1:]
            dest.write_text("\n".join([head] + body) + "\n")
        elif dest.name == "index.json":
            merged = []
            for f in files:
                merged += json.loads(f.read_text())
            dest.write_text(json.dumps(merged, indent=1))
        else:
            dest.write_text(json.dumps([json.loads(f.read_text()) for f in files], indent=1))
    print(f"merged {len(args) - 1} trees into {out}")
    return 0


def recompress(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return False
    pos, chunks = 8, []
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunks.append((kind, data[pos + 8:pos + 8 + n]))
        pos += 12 + n
    idat = b"".join(c for k, c in chunks if k == b"IDAT")
    if idat[:2] != b"\x78\x01":
        return False
    raw = zlib.decompress(idat)
    ihdr = next(c for k, c in chunks if k == b"IHDR")
    w, h = struct.unpack(">II", ihdr[:8])
    stride = w * 3
    rows = bytearray()
    prev = bytes(stride)
    for y in range(h):
        line = raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)]
        up = bytes((line[i] - prev[i]) & 255 for i in range(stride))
        rows += b"\x02" + up
        prev = line
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(
            ">I", zlib.crc32(kind + payload) & 0xffffffff)
    out = data[:8] + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b"")
    path.write_bytes(out)
    return True


def cmd_compress(args):
    n = 0
    for f in Path(args[0]).rglob("*.png"):
        n += recompress(f)
    print(f"recompressed {n} PNGs")
    return 0


def cmd_local(args):
    manifests, env = [], dict(os.environ)
    out, i = "renderlab-out/reference", 0
    while i < len(args):
        a = args[i]
        if a in ("--plates", "--out", "--lut", "--shard", "--max-edge"):
            v = args[i + 1]
            key = {"--plates": "LUMEN_RENDERLAB_PLATES", "--out": "LUMEN_RENDERLAB_OUT",
                   "--lut": "LUMEN_RENDERLAB_LUT", "--shard": "LUMEN_RENDERLAB_SHARD",
                   "--max-edge": "LUMEN_RENDERLAB_MAX_EDGE"}[a]
            env[key] = str(Path(v).resolve()) if a in ("--plates", "--out") else v
            if a == "--out":
                out = v
            i += 2
        else:
            manifests.append(str(Path(a).resolve()))
            i += 1
    env["LUMEN_RENDERLAB"] = ",".join(manifests)
    env.setdefault("LUMEN_RENDERLAB_OUT", str(Path(out).resolve()))
    env["PATH"] = "/opt/swift/usr/bin:" + env.get("PATH", "")
    # `swift test -c release` (not `swift build`) so @testable imports are compiled in.
    start = time.time()
    run = subprocess.run(["swift", "test", "-c", "release", "--filter",
                          "RenderLabReferenceHarness"], cwd=ROOT, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in run.stdout.splitlines():
        if line.startswith("renderlab: ") or "error:" in line:
            print(line)
    print(f"reference run: {time.time() - start:.1f} s")
    cmd_compress([env["LUMEN_RENDERLAB_OUT"]])
    cmd_table([env["LUMEN_RENDERLAB_OUT"]])
    return run.returncode


def cmd_plan(args):
    """CI only: resolve dispatch inputs, or docs/renderlab-request.json on a push."""
    env = os.environ
    req = {
        "manifest": env.get("IN_MANIFEST", ""), "manifests": env.get("IN_MANIFESTS", ""),
        "lane": env.get("IN_LANE", ""), "shards": env.get("IN_SHARDS", ""),
        "drift": env.get("IN_DRIFT", ""), "plates": env.get("IN_PLATES", ""),
        "runs-on": env.get("IN_RUNS_ON", ""),
    }
    request_file = ROOT / "docs/renderlab-request.json"
    if env.get("EVENT") == "push" and request_file.exists():
        req.update(json.loads(request_file.read_text()))
        print(f"push request: {json.dumps(req)[:2000]}")
    resolved = ROOT / "resolved"
    resolved.mkdir(exist_ok=True)
    names = []
    inline = req.get("manifest") or ""
    if inline:
        data = inline if isinstance(inline, (dict, list)) else json.loads(inline)
        (resolved / "inline.json").write_text(json.dumps(data))
        names.append("inline")
    wanted = req.get("manifests") or ""
    if isinstance(wanted, list):
        wanted = ",".join(wanted)
    if not wanted and not inline:
        wanted = "smoke"
    for n in [x.strip() for x in wanted.split(",") if x.strip()]:
        if not all(c.isalnum() or c in "._-" for c in n):
            raise SystemExit(f"bad manifest name {n}")
        src = ROOT / "renderlab/manifests" / f"{n}.json"
        if not src.exists():
            raise SystemExit(f"no {src}")
        json.loads(src.read_text())
        shutil.copy(src, resolved / src.name)
        names.append(n)
    lane = (req.get("lane") or "macos").strip()
    if lane not in ("macos", "linux", "both"):
        raise SystemExit("lane must be macos, linux or both")
    try:
        shards = max(1, min(20, int(req.get("shards") or 4)))
    except ValueError:
        shards = 4
    drift = str(req.get("drift") or "").strip()
    if drift and not all(c.isalnum() or c in "._-" for c in drift):
        raise SystemExit("bad drift name")
    runs_on = str(req.get("runs-on") or "macos-15").strip()
    if not all(c.isalnum() or c in "._-" for c in runs_on):
        raise SystemExit("bad runs-on")
    photo_ids = ",".join(l.split(";")[0] for l in (ROOT / "renderlab/photos.tsv").read_text().splitlines() if l)
    out = {
        "manifests": ",".join(names),
        "macos": str(lane in ("macos", "both")).lower(),
        "linux": str(lane in ("linux", "both")).lower(),
        "shards": json.dumps(list(range(shards))),
        "drift": drift,
        "plates_force": str(str(req.get("plates")).lower() == "true").lower(),
        "runs_on": runs_on,
        "plates_key": f"renderlab-plates-v1-{env.get('PLATES_HASH', '')}-{env.get('PLATE_EDGE', '2048')}",
        "photo_ids": photo_ids,
    }
    with open(env.get("GITHUB_OUTPUT", "/dev/stdout"), "a") as f:
        for k, v in out.items():
            f.write(f"{k}={v}\n")
    print(json.dumps(out, indent=1))
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    fn = globals().get("cmd_" + sys.argv[1])
    if not fn:
        print(__doc__)
        return 2
    return fn(sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
