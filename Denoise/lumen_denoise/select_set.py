"""Pick benchmark/training files from data/drive_index.csv -> data/lists/*.txt (drive paths, read-only use).

clean_train / clean_val : base-ISO, reasonably fast shutter (ground truth), split by shoot date
calib                   : up to 6 frames for every (camera, ISO) present
real_noisy              : high-ISO real shots across ISO bands for visual evaluation
"""
import csv, random
from collections import defaultdict
from pathlib import Path

random.seed(1)
BASE = {"ILCE-7M4": 200, "DMC-GX85": 200}
NOISY_MIN = {"ILCE-7M4": 3200, "DMC-GX85": 1600}
N_CLEAN = {"ILCE-7M4": 260, "DMC-GX85": 140}


def shutter(s):
    try:
        if "/" in s:
            a, b = s.split("/"); return float(a) / float(b)
        return float(s)
    except ValueError:
        return 1.0


rows = [r for r in csv.DictReader(open("data/drive_index.csv")) if r.get("Model") in BASE and r.get("ISO")]
for r in rows:
    r["iso"] = float(r["ISO"]); r["t"] = shutter(r.get("ExposureTime", "")); r["date"] = (r.get("DateTimeOriginal") or "")[:10]
# de-duplicate the same photo stored in several folders (same camera, timestamp, name)
seen, uniq = set(), []
for r in rows:
    k = (r["Model"], r.get("DateTimeOriginal"), Path(r["SourceFile"]).name.split("-")[0].split(".")[0])
    if k not in seen:
        seen.add(k); uniq.append(r)
rows = uniq
lists = defaultdict(list)


def spread(pool, n):
    """n files spread evenly across shoot dates (diversity of scenes)."""
    by = defaultdict(list)
    for r in pool: by[r["date"]].append(r)
    for v in by.values(): random.shuffle(v)
    out, days = [], sorted(by)
    while len(out) < n and any(by.values()):
        for d in days:
            if by[d] and len(out) < n: out.append(by[d].pop())
    return out


for cam in BASE:
    mine = [r for r in rows if r["Model"] == cam]
    clean = [r for r in mine if r["iso"] <= BASE[cam] and r["t"] <= 1 / 60]
    days = sorted({r["date"] for r in clean}); random.shuffle(days)
    val_days = set(days[: max(2, len(days) // 7)])
    tr = spread([r for r in clean if r["date"] not in val_days], N_CLEAN[cam])
    va = spread([r for r in clean if r["date"] in val_days], 24)
    lists["clean_train"] += tr; lists["clean_val"] += va
    by_iso = defaultdict(list)
    for r in mine: by_iso[r["iso"]].append(r)
    for iso, v in by_iso.items():
        lists["calib"] += spread(v, 6)
    noisy = [r for r in mine if r["iso"] >= NOISY_MIN[cam]]
    bands = defaultdict(list)
    for r in noisy: bands[min(int(r["iso"]).bit_length(), 16)].append(r)
    for b, v in bands.items():
        lists["real_noisy"] += spread(v, 8)
    print(cam, "total", len(mine), "clean", len(clean), "train", len(tr), "val", len(va), "val_days", len(val_days),
          "noisy", len(noisy), "ISOs", sorted(by_iso))

Path("data/lists").mkdir(exist_ok=True)
for k, v in lists.items():
    Path(f"data/lists/{k}.txt").write_text("\n".join(r["SourceFile"] for r in v) + "\n")
    print(k, len(v))
