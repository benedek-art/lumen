#!/usr/bin/env python3
"""Run `lumen-render auto` on every corpus frame and write a before/after sheet + table.

usage: auto_corpus.py OUTDIR [--ids 6929,6933] [--long-edge 640] [--set k=v ...]
Writes OUTDIR/<id>.json, OUTDIR/<id>_before.png, OUTDIR/<id>_after.png,
OUTDIR/summary.json and OUTDIR/sheet.png (before | after pairs, 3 pairs per row).
"""
import argparse, glob, json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../../.."))
BIN = os.path.join(ROOT, ".build/x86_64-unknown-linux-gnu/release/lumen-render")


def frames(ids):
    out = []
    for p in sorted(glob.glob(os.path.join(ROOT, "corpus/lfi/*.lfi"))):
        fid = os.path.basename(p).split("_")[0]
        if ids and fid not in ids:
            continue
        out.append((fid, p))
    return out


def run(fid, path, outdir, long_edge, sets, legacy=False):
    hint = json.load(open(path[:-4] + ".json")).get("recipe_hint", {})
    cmd = [BIN, "auto", "--input", path, "--long-edge", str(long_edge),
           "--as-shot-kelvin", str(hint.get("asShotKelvin", 5500)),
           "--as-shot-tint", str(hint.get("asShotTint", 0)),
           "--out-before", f"{outdir}/{fid}_before.png",
           "--out-after", f"{outdir}/{fid}_after.png",
           "--report", f"{outdir}/{fid}.json"]
    if hint.get("captureISO"):
        cmd += ["--iso", str(hint["captureISO"])]
    for s in sets:
        cmd += ["--set", s]
    if legacy:
        cmd += ["--legacy"]
    subprocess.run(cmd, check=True, capture_output=True)
    return fid


def sheet(outdir, ids, path):
    from PIL import Image, ImageDraw
    cell = 300
    per_row = 3
    rows = (len(ids) + per_row - 1) // per_row
    W, H = per_row * (2 * cell + 16), rows * (cell + 22)
    img = Image.new("RGB", (W, H), (40, 40, 40))
    d = ImageDraw.Draw(img)
    for k, fid in enumerate(ids):
        x0 = (k % per_row) * (2 * cell + 16)
        y0 = (k // per_row) * (cell + 22)
        for j, tag in enumerate(("before", "after")):
            im = Image.open(f"{outdir}/{fid}_{tag}.png")
            im.thumbnail((cell, cell))
            img.paste(im, (x0 + j * (cell + 4) + (cell - im.width) // 2, y0 + 18 + (cell - im.height) // 2))
        r = json.load(open(f"{outdir}/{fid}.json"))["suggestion"]
        d.text((x0 + 2, y0 + 3), f"{fid}  E{r['exposure']:+.2f} C{r['contrast']:+.0f} H{r['highlights']:+.0f} "
               f"S{r['shadows']:+.0f} W{r['whites']:+.0f} B{r['blacks']:+.0f} V{r['vibrance']:+.0f}",
               fill=(230, 230, 230))
    img.save(path, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--ids", default="")
    ap.add_argument("--long-edge", type=int, default=640)
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--sheet", default="")
    ap.add_argument("--legacy", action="store_true", help="the pre-WS-09 Auto")
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    ids = set(a.ids.split(",")) if a.ids else None
    fs = frames(ids)
    with ThreadPoolExecutor(4) as ex:
        done = list(ex.map(lambda f: run(f[0], f[1], a.outdir, a.long_edge, a.set, a.legacy), fs))
    summary = {}
    print(f"{'id':>5} {'E':>6} {'C':>4} {'H':>4} {'S':>4} {'W':>4} {'B':>4} {'V':>3} | "
          f"{'med0':>5} {'med1':>5} {'mean1':>5} {'p1':>5} {'p99':>5} {'clipH%':>6} {'clipS%':>6}")
    for fid in done:
        r = json.load(open(f"{a.outdir}/{fid}.json"))
        s, b, af = r["suggestion"], r["before"], r["after"]
        L, Lb = af["luminance"], b["luminance"]
        row = dict(suggestion=s,
                   before=dict(median=Lb["medianEncoded"], mean=Lb["meanEncoded"],
                               p1=Lb["percentilesEncoded"]["p1"], p99=Lb["percentilesEncoded"]["p99"],
                               clipH=b["clipping"]["highlightsPct"]["any"], clipS=b["clipping"]["shadowsPct"]["any"]),
                   after=dict(median=L["medianEncoded"], mean=L["meanEncoded"],
                              p1=L["percentilesEncoded"]["p1"], p99=L["percentilesEncoded"]["p99"],
                              clipH=af["clipping"]["highlightsPct"]["any"], clipS=af["clipping"]["shadowsPct"]["any"],
                              chroma=af["colour"]["meanChroma"]),
                   beforeChroma=b["colour"]["meanChroma"])
        summary[fid] = row
        A = row["after"]
        print(f"{fid:>5} {s['exposure']:+6.2f} {s['contrast']:+4.0f} {s['highlights']:+4.0f} {s['shadows']:+4.0f} "
              f"{s['whites']:+4.0f} {s['blacks']:+4.0f} {s['vibrance']:+3.0f} | {row['before']['median']:.3f} "
              f"{A['median']:.3f} {A['mean']:.3f} {A['p1']:.3f} {A['p99']:.3f} {A['clipH']:6.2f} {A['clipS']:6.2f}")
    json.dump(summary, open(f"{a.outdir}/summary.json", "w"), indent=1, sort_keys=True)
    if a.sheet:
        sheet(a.outdir, sorted(done, key=lambda x: int(x) if x.isdigit() else 0), a.sheet)


if __name__ == "__main__":
    main()
