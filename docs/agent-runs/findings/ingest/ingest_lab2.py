#!/usr/bin/env python3
"""More ingest checks: sequence order across a folder rollover, a frame vanishing after the
scan (card pulled / file deleted), and a primary destination that fills up mid-run while the
backup has room. usage: python3 ingest_lab2.py <harness> <workdir> <small-tmpfs-mount>"""
import hashlib, json, os, random, shutil, subprocess, sys, threading, time

HARNESS, WORK, SMALL = sys.argv[1:4]
res = []
def check(n, ok, d=""):
    res.append((n, bool(ok), str(d))); print(("PASS " if ok else "FAIL ") + n + (" :: " + str(d) if d else ""))
def sha(p):
    h = hashlib.sha256(); h.update(open(p, "rb").read()); return h.hexdigest()
def w(p, n, seed, t):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(random.Random(seed).randbytes(n)); os.utime(p, (t, t))
def files(root):
    return sorted(os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs)
def run(card, prim, back, ft, rt, tag, extra=()):
    out = os.path.join(WORK, tag + ".json")
    p = subprocess.run([HARNESS, card, prim, back or "-", ft, rt or "-", "-", out, *extra],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    r = json.load(open(out)); print(f"  [{tag}] {r['summary']}"); return r

os.makedirs(WORK, exist_ok=True)
# ---- T9: counter rollover 100MSDCF/DSC09998..9999 then 101MSDCF/DSC00001..2 (shot later)
card = os.path.join(WORK, "card9"); shutil.rmtree(card, ignore_errors=True)
w(f"{card}/DCIM/100MSDCF/DSC09998.ARW", 1000, 1, 1764000000)
w(f"{card}/DCIM/100MSDCF/DSC09999.ARW", 1000, 2, 1764000010)
w(f"{card}/DCIM/101MSDCF/DSC00001.ARW", 1000, 3, 1764000020)
w(f"{card}/DCIM/101MSDCF/DSC00002.ARW", 1000, 4, 1764000030)
P = os.path.join(WORK, "t9"); shutil.rmtree(P, ignore_errors=True); os.makedirs(P)
r = run(card, P, None, "", "{seq:4}-{orig}", "t9")
order = [(os.path.relpath(x["source"], card), os.path.basename(x["destination"])) for x in r["results"]]
print("  t9 seq assignment:", order)
check("T9: {seq} follows shooting order across a folder rollover (DSC09998 gets 0001)",
      os.path.basename(order[0][1]).startswith("0001-DSC09998"), order)
json.dump(order, open(os.path.join(WORK, "t9-order.json"), "w"), indent=1)

# ---- T12: a frame disappears after the scan (card pulled / deleted from camera)
card = os.path.join(WORK, "card12"); shutil.rmtree(card, ignore_errors=True)
for i in range(1, 6):
    w(f"{card}/DCIM/100/IMG_{i:04d}.CR3", 8_000_000, 20 + i, 1764000000 + i)
P = os.path.join(WORK, "t12"); shutil.rmtree(P, ignore_errors=True); os.makedirs(P)
# delete frame 3 while frame 1/2 are being copied (small chunks slow the run)
def killer():
    time.sleep(0.05)
    try: os.remove(f"{card}/DCIM/100/IMG_0003.CR3")
    except FileNotFoundError: pass
th = threading.Thread(target=killer); th.start()
r = run(card, P, None, "", None, "t12", ["--chunk", "4096"]); th.join()
kinds = {os.path.basename(x["source"]): x["outcome"]["kind"] for x in r["results"]}
print("  t12 outcomes:", kinds)
check("T12: vanished frame reported failed, others verified, not allVerified",
      kinds.get("IMG_0003.CR3") == "failed" and not r["allVerified"]
      and sum(v == "verified" for v in kinds.values()) == 4, kinds)
check("T12: summary names the failure", "IMG_0003.CR3" in r["summary"], r["summary"])
check("T12: no partial/hidden files", not [f for f in files(P) if os.path.basename(f).startswith(".")])

# ---- T13: primary fills up mid-run, backup has room
card = os.path.join(WORK, "card13"); shutil.rmtree(card, ignore_errors=True)
for i in range(1, 6):
    w(f"{card}/DCIM/100/IMG_{i:04d}.CR3", 3_000_000, 40 + i, 1764000000 + i)
for f in os.listdir(SMALL):
    shutil.rmtree(os.path.join(SMALL, f), ignore_errors=True)
PF = os.path.join(SMALL, "primary"); os.makedirs(PF)
B = os.path.join(WORK, "t13-backup"); shutil.rmtree(B, ignore_errors=True); os.makedirs(B)
r = run(card, PF, B, "", None, "t13")
on_primary = files(PF)
print("  t13 primary files:", [(os.path.basename(f), os.path.getsize(f)) for f in on_primary])
check("T13: no partial or hidden file left on the full primary",
      all(os.path.getsize(f) == 3_000_000 and not os.path.basename(f).startswith(".") for f in on_primary),
      [(os.path.basename(f), os.path.getsize(f)) for f in on_primary])
check("T13: backup received every frame intact", len(files(B)) == 5 and
      all(sha(f) == sha(os.path.join(card, "DCIM/100", os.path.basename(f))) for f in files(B)))
check("T13: run not reported as fully verified; summary names the full disk",
      not r["allVerified"] and "failed" in r["summary"], r["summary"])
json.dump([{"name": n, "ok": o, "detail": d} for n, o, d in res],
          open(os.path.join(WORK, "checks2.json"), "w"), indent=1)
print(f"\n{sum(o for _, o, _ in res)}/{len(res)} checks passed")
