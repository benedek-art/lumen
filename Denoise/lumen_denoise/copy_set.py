"""Copy the selected RAWs OFF the drive into data/raw/ (read-only on the source).
Writes data/lists/local_<list>.txt and data/raw/manifest.csv (local name -> original drive path)."""
import csv, hashlib, shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

DST = Path("data/raw"); DST.mkdir(parents=True, exist_ok=True)
lists = {p.stem: [l for l in p.read_text().splitlines() if l] for p in Path("data/lists").glob("*.txt") if not p.stem.startswith("local_")}
srcs = sorted({s for v in lists.values() for s in v})


def local(src):
    p = Path(src)
    return DST / f"{p.stem}_{hashlib.md5(src.encode()).hexdigest()[:6]}{p.suffix}"


def cp(src):
    d = local(src)
    if not d.exists():
        shutil.copyfile(src, d.with_suffix(".part"))  # copies bytes only; source opened read-only
        d.with_suffix(".part").rename(d)
    return d


with ThreadPoolExecutor(4) as ex:
    for i, d in enumerate(ex.map(cp, srcs)):
        if i % 50 == 0: print(i, len(srcs), d, flush=True)
with open(DST / "manifest.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["local", "original"])
    for s in srcs: w.writerow([local(s).name, s])
for k, v in lists.items():
    Path(f"data/lists/local_{k}.txt").write_text("\n".join(str(local(s)) for s in v) + "\n")
print("copied", len(srcs))
