#!/usr/bin/env python3
"""Evaluate WS-09 SPEC lines S1-S7 from an auto_corpus.py output directory.

usage: spec_check.py RUNDIR [--legacy LEGACYDIR]
Prints each line's measured number, threshold and PASS/FAIL (and the legacy number).
"""
import json, sys

LOW_KEY = {"2348", "967"}          # black jacket, black bag: low-key by intent


def load(d):
    out = {}
    for fid, row in json.load(open(f"{d}/summary.json")).items():
        full = json.load(open(f"{d}/{fid}.json"))
        row["predicted"] = full.get("predicted", {})
        out[fid] = row
    return out


def lines(r):
    ids = sorted(r)
    med = {i: r[i]["after"]["median"] for i in ids}
    res = []
    # S1 key
    # Protection-bound: Exposure stopped short of the key (headroom cap or clip loop),
    # which Auto's own prediction shows as a predicted median under the key.
    bound = {i for i in ids if r[i]["suggestion"].get("clipRefinements", 0) > 0
             or r[i]["predicted"].get("0.5", 1) < 0.40}
    free = [i for i in ids if i not in bound]
    inkey = [i for i in free if 0.38 <= med[i] <= 0.46]
    res.append(("S1 median in 0.38-0.46 where protection did not bind; none above 0.46",
                f"{len(inkey)}/{len(free)} (bound: {sorted(bound)})",
                len(inkey) == len(free) and max(med.values()) <= 0.46))
    # S2 low key
    lk = max(med[i] for i in LOW_KEY)
    res.append(("S2 low-key frames median <= 0.30", f"{lk:.3f}", lk <= 0.30))
    # S3 clipping
    worst = max(r[i]["after"]["clipH"] - max(r[i]["before"]["clipH"], 0) for i in ids)
    bad = [i for i in ids if r[i]["after"]["clipH"] > max(0.5, r[i]["before"]["clipH"] + 0.5)]
    res.append(("S3 highlight clip <= max(0.5%, before+0.5%)", f"worst +{worst:.2f}% {bad}", not bad))
    worst = max(r[i]["after"]["clipS"] - r[i]["before"]["clipS"] for i in ids)
    bad = [i for i in ids if r[i]["after"]["clipS"] > max(0.5, r[i]["before"]["clipS"] + 0.5)]
    res.append(("S4 shadow crush <= max(0.5%, before+0.5%)", f"worst +{worst:.2f}% {bad}", not bad))
    # S5 endpoints
    hi = [i for i in ids if r[i]["after"]["p99"] >= 0.85]
    lo = [i for i in ids if r[i]["after"]["p1"] <= 0.05]
    short = [i for i in ids if i not in hi]
    excused = [i for i in short if i in bound or r[i]["suggestion"]["whites"] >= 60]
    res.append(("S5a p99 >= 0.85 on >= 18/25; every short frame has Whites at +60 or is protection-bound",
                f"{len(hi)}/25, short {short}", len(hi) >= 18 and excused == short))
    res.append(("S5b p1 <= 0.05", f"{len(lo)}/25", len(lo) >= 21))
    # S6 consistency
    a, b = r["6929"], r["6933"]
    dm = abs(a["after"]["median"] - b["after"]["median"])
    dmean = abs(a["after"]["mean"] - b["after"]["mean"])
    res.append(("S6 6929 vs 6933 |d median| <= 0.01, |d mean| <= 0.02",
                f"{dm:.3f} / {dmean:.3f}", dm <= 0.01 and dmean <= 0.02))
    # S7 vibrance
    v = [r[i]["suggestion"]["vibrance"] for i in ids]
    res.append(("S7 vibrance in 5..15", f"{min(v):.0f}..{max(v):.0f}", min(v) >= 5 and max(v) <= 15))
    # S8 prediction
    errs = [abs(r[i]["predicted"].get("0.5", -9) - med[i]) for i in ids]
    res.append(("S8 |predicted - rendered median| <= 0.02", f"max {max(errs):.3f}", max(errs) <= 0.02))
    return res


def main():
    r = load(sys.argv[1])
    legacy = load(sys.argv[sys.argv.index("--legacy") + 1]) if "--legacy" in sys.argv else None
    ll = {n: m for n, m, _ in lines(legacy)} if legacy else {}
    for name, measured, ok in lines(r):
        extra = f"   (legacy: {ll[name]})" if name in ll else ""
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {measured}{extra}")


if __name__ == "__main__":
    main()
