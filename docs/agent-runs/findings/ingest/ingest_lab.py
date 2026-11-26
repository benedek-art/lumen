#!/usr/bin/env python3
"""Independent black-box checks of Lumen's ingest copy engine (LumenCore IngestPlanner +
VerifiedCopyDriver) on synthetic card folders. Runs the Swift harness, then verifies with
Python's own sha256 that every copied byte matches, the source is untouched, the backup is
identical, collisions never overwrite, a stop leaves no partial files, and a re-run completes.

usage: python3 ingest_lab.py <harness-binary> <workdir>
"""
import hashlib, json, os, random, shutil, subprocess, sys, time

HARNESS, WORK = sys.argv[1], sys.argv[2]
results = []

def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + (" :: " + str(detail) if detail else ""))

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def snapshot(root):
    """Every entry under root (hidden included): path -> (size, mtime_ns, sha256 or 'dir')."""
    snap = {}
    for d, dirs, files in os.walk(root):
        for x in dirs:
            p = os.path.join(d, x); snap[os.path.relpath(p, root)] = ("dir",)
        for x in files:
            p = os.path.join(d, x); st = os.stat(p)
            snap[os.path.relpath(p, root)] = (st.st_size, st.st_mtime_ns, sha(p))
    return snap

def files_under(root):
    out = []
    for d, _, files in os.walk(root):
        for x in files:
            out.append(os.path.join(d, x))
    return sorted(out)

def write_rand(p, n, seed):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    r = random.Random(seed)
    with open(p, "wb") as f:
        left = n
        while left:
            k = min(left, 1 << 20); f.write(r.randbytes(k)); left -= k
    t = 1764000000 + seed * 7  # fixed capture-ish mtimes
    os.utime(p, (t, t))

def make_card(card):
    shutil.rmtree(card, ignore_errors=True)
    seed = 1
    # 100MSDCF: 8 RAW, 3 of them with a JPEG twin; one 40 MB RAW
    for i in range(1, 9):
        size = 40_000_000 if i == 4 else 3_000_000 + i * 1111
        write_rand(f"{card}/DCIM/100MSDCF/DSC0000{i}.ARW", size, seed); seed += 1
        if i in (2, 5, 7):
            write_rand(f"{card}/DCIM/100MSDCF/DSC0000{i}.JPG", 800_000 + i, seed); seed += 1
    # 101MSDCF: same basenames as 100 (counter reset / second body), different bytes
    for i in range(1, 4):
        write_rand(f"{card}/DCIM/101MSDCF/DSC0000{i}.ARW", 2_500_000 + i, seed); seed += 1
    write_rand(f"{card}/DCIM/101MSDCF/DSC00002.JPG", 700_000, seed); seed += 1
    # non-photo payloads a real card carries
    write_rand(f"{card}/PRIVATE/M4ROOT/CLIP/C0001.MP4", 5_000_000, seed); seed += 1
    write_rand(f"{card}/PRIVATE/M4ROOT/THMBNL/C0001T01.JPG", 20_000, seed); seed += 1
    write_rand(f"{card}/DCIM/100MSDCF/DSC00009.MOV", 3_000_000, seed); seed += 1
    write_rand(f"{card}/DCIM/100MSDCF/DSC00003.WAV", 100_000, seed); seed += 1
    write_rand(f"{card}/DCIM/100MSDCF/DSC00003.XMP", 2_000, seed); seed += 1
    write_rand(f"{card}/DCIM/100MSDCF/._DSC00001.ARW", 4096, seed); seed += 1  # AppleDouble

def run(card, primary, backup, folder_t, rename_t, job, tag, extra=()):
    out = os.path.join(WORK, tag + ".json")
    cmd = [HARNESS, card, primary, backup or "-", folder_t, rename_t or "-", job or "-", out, *extra]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stdout, p.stderr); raise SystemExit("harness failed")
    rep = json.load(open(out))
    print(f"  [{tag}] summary: {rep.get('summary')}")
    return rep

def verify_landed(rep, tag, src_snap_before, card):
    """sha256 of every landed destination equals its source."""
    bad = []
    n = 0
    for r in rep["results"]:
        if r["outcome"]["kind"] in ("verified", "copied", "alreadyPresent"):
            n += 1
            if sha(r["destination"]) != sha(r["source"]):
                bad.append(r["destination"])
    check(f"{tag}: sha256(dest)==sha256(source) for all {n} landed copies", not bad, bad[:3])

os.makedirs(WORK, exist_ok=True)

# ---------------------------------------------------------------- T1 full ingest, defaults
card = os.path.join(WORK, "card1"); make_card(card)
before = snapshot(card)
P, B = os.path.join(WORK, "t1/primary"), os.path.join(WORK, "t1/backup")
shutil.rmtree(os.path.join(WORK, "t1"), ignore_errors=True); os.makedirs(P); os.makedirs(B)
rep = run(card, P, B, "{year}/{date} {job}", "{date}-{seq:4}-{orig}", "Wedding", "t1")
after = snapshot(card)
check("T1: source tree byte-, size- and mtime-identical after ingest, no new entries",
      before == after, set(after) ^ set(before))
verify_landed(rep, "T1", before, card)
nphotos = len(rep["scanned"])
check("T1: every scanned photo has a verified primary AND backup",
      sum(1 for r in rep["results"] if r["outcome"]["kind"] == "verified") == 2 * nphotos,
      f"{nphotos} scanned")
check("T1: allVerified (would unlock eject)", rep["allVerified"], rep["summary"])
prim = [os.path.relpath(f, P) for f in files_under(P)]
back = [os.path.relpath(f, B) for f in files_under(B)]
check("T1: backup tree has the same names as primary", prim == back)
check("T1: backup bytes identical to primary",
      all(sha(os.path.join(P, x)) == sha(os.path.join(B, x)) for x in prim))
check("T1: no .part / hidden files left in destinations",
      not [f for f in prim if os.path.basename(f).startswith(".")])
scanned_rel = sorted(os.path.relpath(s, card) for s in rep["scanned"])
not_scanned = sorted(k for k, v in before.items() if v[0] != "dir" and k not in scanned_rel)
print("  scanned:", scanned_rel)
print("  on card but NOT ingested:", not_scanned)
print("  primary tree:", prim)
# mtime preservation
mt = [(r["source"], r["destination"]) for r in rep["results"] if r["role"] == "primary"]
same_mtime = sum(1 for s, d in mt if int(os.stat(s).st_mtime) == int(os.stat(d).st_mtime))
check("T1: destination keeps the source file's modification date", same_mtime == len(mt),
      f"{same_mtime}/{len(mt)} kept; e.g. src {time.ctime(os.stat(mt[0][0]).st_mtime)} "
      f"dst {time.ctime(os.stat(mt[0][1]).st_mtime)}")
# RAW+JPEG twin share stem
stems = {}
for r in rep["results"]:
    if r["role"] == "primary":
        stems.setdefault(os.path.splitext(r["source"])[0], set()).add(
            os.path.splitext(os.path.basename(r["destination"]))[0])
check("T1: each RAW+JPEG pair lands under one stem", all(len(v) == 1 for v in stems.values()),
      {k: v for k, v in stems.items() if len(v) > 1})
json.dump({"scanned": scanned_rel, "not_ingested": not_scanned, "primary": prim},
          open(os.path.join(WORK, "t1-tree.json"), "w"), indent=1)

# ---------------------------------------------------------------- T2 templates
for tmpl in ["{date}-{seq4}-{orig}", "{date}-{seq:4}-{orig}", "{seq}-{orig}", "{seq:2}_{orig}"]:
    d = os.path.join(WORK, "t2", tmpl.replace("{", "").replace("}", "").replace(":", "_"))
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    rep2 = run(card, d, None, "", tmpl, None, "t2-" + os.path.basename(d))
    names = sorted(os.path.basename(f) for f in files_under(d))
    print(f"  template {tmpl!r}: unknown={rep2['unknownTokensRename']} first names={names[:4]}")
    json.dump({"template": tmpl, "unknown": rep2["unknownTokensRename"], "names": names},
              open(d + ".names.json", "w"), indent=1)
check("T2: {seq4} is flagged as unknown token (sheet blocks Start)",
      json.load(open(os.path.join(WORK, "t2", "date-seq4-orig.names.json")))["unknown"] == ["seq4"])
n4 = json.load(open(os.path.join(WORK, "t2", "date-seq_4-orig.names.json")))["names"]
check("T2: {seq:4} renders 4-digit counter", any("-0001-" in n for n in n4), n4[:2])

# ---------------------------------------------------------------- T3 collisions
P3 = os.path.join(WORK, "t3/primary"); shutil.rmtree(os.path.join(WORK, "t3"), ignore_errors=True)
os.makedirs(P3)
# a stranger already at the destination with a card name
write_rand(os.path.join(P3, "DSC00001.ARW"), 1234, 999)
stranger = sha(os.path.join(P3, "DSC00001.ARW"))
rep3 = run(card, P3, None, "", None, None, "t3")  # rename OFF, flat folder: 100 & 101 collide
check("T3: pre-existing stranger file not overwritten", sha(os.path.join(P3, "DSC00001.ARW")) == stranger)
verify_landed(rep3, "T3", None, card)
dests = [r["destination"] for r in rep3["results"]]
check("T3: no two frames share one destination file", len(dests) == len(set(dests)))
check("T3: every scanned frame landed", sum(1 for r in rep3["results"]
      if r["outcome"]["kind"] == "verified") == len(rep3["scanned"]), rep3["summary"])
print("  t3 tree:", sorted(os.path.basename(f) for f in files_under(P3)))
# pairs across folders: 101/DSC00002.ARW+JPG must share a stem
st = {}
for r in rep3["results"]:
    st.setdefault(os.path.splitext(r["source"])[0], set()).add(os.path.splitext(os.path.basename(r["destination"]))[0])
check("T3: RAW+JPEG pairs keep one stem through collision renames", all(len(v) == 1 for v in st.values()), st)

# ---------------------------------------------------------------- T4 stop mid-file + re-run
P4, B4 = os.path.join(WORK, "t4/primary"), os.path.join(WORK, "t4/backup")
shutil.rmtree(os.path.join(WORK, "t4"), ignore_errors=True); os.makedirs(P4); os.makedirs(B4)
# 40 MB DSC00004.ARW is 5th in order; cancel 10 MB into it
pre = sum(os.path.getsize(os.path.join(card, "DCIM/100MSDCF", f)) for f in
          ["DSC00001.ARW", "DSC00002.ARW", "DSC00002.JPG", "DSC00003.ARW"])
pre += sum(os.path.getsize(os.path.join(card, "DCIM/101MSDCF", f)) for f in
           ["DSC00001.ARW", "DSC00002.ARW", "DSC00002.JPG", "DSC00003.ARW"])
rep4 = run(card, P4, B4, "{year}/{date} {job}", "{date}-{seq:4}-{orig}", "Stop", "t4a",
           ["--cancel-after-bytes", str(pre + 10_000_000), "--chunk", "1048576"])
everything = files_under(P4) + files_under(B4)
check("T4: stop reported as cancelled", rep4["wasCancelled"], rep4["summary"])
check("T4: no .part or hidden files after stop", not [f for f in everything if os.path.basename(f).startswith(".")],
      [f for f in everything if os.path.basename(f).startswith(".")])
landed = {r["destination"] for r in rep4["results"]}
check("T4: every file on disk after stop is a reported, verified copy",
      set(everything) == landed, set(everything) ^ landed)
verify_landed(rep4, "T4a", None, card)
check("T4: no destination file is shorter than its source",
      all(os.path.getsize(r["destination"]) == os.path.getsize(r["source"]) for r in rep4["results"]))
n_after_stop = len(everything)
rep4b = run(card, P4, B4, "{year}/{date} {job}", "{date}-{seq:4}-{orig}", "Stop", "t4b")
verify_landed(rep4b, "T4b", None, card)
kinds = [r["outcome"]["kind"] for r in rep4b["results"]]
check("T4: re-run completes, already-copied frames reported alreadyPresent (not recopied)",
      kinds.count("alreadyPresent") == n_after_stop and rep4b["allVerified"],
      f"{kinds.count('alreadyPresent')} alreadyPresent, {kinds.count('verified')} verified; {rep4b['summary']}")
check("T4: after re-run, primary holds exactly one copy per frame",
      len(files_under(P4)) == len(rep4b["scanned"]), len(files_under(P4)))

# ---------------------------------------------------------------- T5 re-ingest after the card changed
card5 = os.path.join(WORK, "card5"); shutil.rmtree(card5, ignore_errors=True)
for i in range(1, 7):
    write_rand(f"{card5}/DCIM/100CANON/IMG_000{i}.CR3", 1_000_000 + i, 500 + i)
P5 = os.path.join(WORK, "t5/primary"); shutil.rmtree(os.path.join(WORK, "t5"), ignore_errors=True); os.makedirs(P5)
r5a = run(card5, P5, None, "{job}", "{date}-{seq:4}-{orig}", "Trip", "t5a")
# photographer deletes a reject in camera, shoots two more, re-ingests the same card
os.remove(f"{card5}/DCIM/100CANON/IMG_0002.CR3")
for i in (7, 8):
    write_rand(f"{card5}/DCIM/100CANON/IMG_000{i}.CR3", 1_000_000 + i, 500 + i)
r5b = run(card5, P5, None, "{job}", "{date}-{seq:4}-{orig}", "Trip", "t5b")
tree5 = sorted(os.path.basename(f) for f in files_under(P5))
digests = {}
for f in files_under(P5):
    digests.setdefault(sha(f), []).append(os.path.basename(f))
dups = {k: v for k, v in digests.items() if len(v) > 1}
print("  t5 tree:", tree5)
check("T5: re-ingest after in-camera delete does not duplicate already-ingested frames",
      not dups, list(dups.values()))
json.dump({"tree": tree5, "duplicates": list(dups.values()), "run2": r5b["summary"]},
          open(os.path.join(WORK, "t5-tree.json"), "w"), indent=1)

# ---------------------------------------------------------------- T6 destination inside the source
card6 = os.path.join(WORK, "card6"); shutil.rmtree(card6, ignore_errors=True)
for i in range(1, 4):
    write_rand(f"{card6}/DCIM/100NIKON/DSC_000{i}.NEF", 500_000 + i, 600 + i)
b6 = snapshot(card6)
r6 = run(card6, card6, None, "{year}/{date} {job}", "{date}-{seq:4}-{orig}", None, "t6a")
a6 = snapshot(card6)
added = sorted(set(a6) - set(b6))
check("T6: choosing the card itself as primary is refused (source must not be written)",
      not added, added)
r6b = run(card6, card6, None, "{year}/{date} {job}", "{date}-{seq:4}-{orig}", None, "t6b")
check("T6: second run on that card does not ingest its own earlier copies as new frames",
      len(r6b["scanned"]) == 3, f"scanned {len(r6b['scanned'])}: {r6b['summary']}")

# ---------------------------------------------------------------- T7 unverified mode / zero-byte
card7 = os.path.join(WORK, "card7"); shutil.rmtree(card7, ignore_errors=True)
write_rand(f"{card7}/DCIM/100/A.ARW", 100_000, 700)
os.makedirs(f"{card7}/DCIM/100", exist_ok=True); open(f"{card7}/DCIM/100/EMPTY.ARW", "wb").close()
P7 = os.path.join(WORK, "t7/primary"); shutil.rmtree(os.path.join(WORK, "t7"), ignore_errors=True); os.makedirs(P7)
r7 = run(card7, P7, None, "", None, None, "t7")
print("  t7 outcomes:", [(os.path.basename(r["source"]), r["outcome"]["kind"]) for r in r7["results"]])

# ---------------------------------------------------------------- T8 backup on the same volume
check("T8: backup on the SAME volume as primary is refused or warned about",
      os.stat(P).st_dev != os.stat(B).st_dev or "volume" in rep["summary"].lower(),
      f"st_dev primary={os.stat(P).st_dev} backup={os.stat(B).st_dev}; summary={rep['summary']!r}")

json.dump([{"name": n, "ok": o, "detail": str(d)} for n, o, d in results],
          open(os.path.join(WORK, "checks.json"), "w"), indent=1)
print(f"\n{sum(o for _, o, _ in results)}/{len(results)} checks passed")
