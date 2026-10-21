#!/usr/bin/env python3
"""Run `lumen-render match` on all 600 ordered corpus pairs (as-shot WB, no EXIF) and print
every pair the overlap measurement accepted, highest correlation first. Only 6929/6933 share a
view in the corpus, so that is the only pair that may appear. Set `overlapThreshold` to -1 to
see the whole distribution. Run from the repo root.
"""
import glob, subprocess, re, itertools, json
from concurrent.futures import ThreadPoolExecutor
B=".build/x86_64-unknown-linux-gnu/release/lumen-render"
fs=sorted(glob.glob("corpus/lfi/*.lfi"))
def kel(p):
    h=json.load(open(p[:-4]+".json")).get("recipe_hint",{})
    return ["--as-shot-kelvin",str(h.get("asShotKelvin",5500)),"--as-shot-tint",str(h.get("asShotTint",0))]
def run(pr):
    a,b=pr
    out=subprocess.run([B,"match","--input",a,"--input",b]+kel(a)+kel(b),capture_output=True,text=True).stdout
    m=re.search(r"^1 measured (\S+) EV \(ncc (\S+)\)",out,re.M)
    return a.split("/")[-1][:4],b.split("/")[-1][:4],m.group(1),m.group(2)
res=list(ThreadPoolExecutor(4).map(run,itertools.permutations(fs,2)))
res=[r for r in res if r[3]!='-']  # measured pairs only
res.sort(key=lambda r:-float(r[3]))
print(len(res)); [print(r) for r in res[:12]]
