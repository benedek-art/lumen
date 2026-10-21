"""WS-16 PAR-1 (Float twin vs Double ColorEngine) and PAR-2 (GLSL finish kernel carries the
same constants as the twin: a structural text check, since the GPU cannot run on Linux).
Usage: python3 m_parity.py"""
import sys, os, re, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

# PAR-1
pts = grid(Cs=(0.005, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12, 0.16, 0.2, 0.25, 0.3), dh=3) + \
      [("rgb", v, v, v) for v in (0.001, 0.05, 0.18, 1.0, 4.0)]
settings = [dict(sat=s) for s in (-100, -50, -25, 25, 50, 100)] + [dict(vib=v) for v in (-100, -50, 50, 100)] + \
           [dict(sat=100, dens=0), dict(sat=100, dens=100), dict(sat=60, vib=60, prot=0), dict(vib=100, prot=100),
            dict(sat=100, prot=100), dict(sat=-40, vib=80, dens=25, prot=40),
            dict(bw=[0] * 8), dict(bw=[-100] + [0] * 7), dict(bw=[50, -50, 100, -100, 30, -70, 0, 20]),
            dict(bw=[-100] * 8), dict(bw=[100] * 8), dict(sat=100, bw=[0, 0, 0, 0, 0, -100, 0, 0])]
worst, where = 0.0, None
for st in settings:
    r = stage(pts, **st)
    ok = in_gamut(r)
    d = (np.abs(r["twRGB"] - r["engRGB"]) / np.maximum(1, np.abs(r["engRGB"])))[ok].max()
    if d > worst:
        worst, where = d, str(st)
check("PAR-1", worst <= 1e-4, f"max |twin - ColorEngine| {worst:.2e} ({where})", "<= 1e-4 (relative to max(1,|x|))")

# PAR-2
src = open(os.path.join(REPO, "Sources", "LumenCore", "Engine", "ExactColorStage.swift")).read()
a = src.index("static func hkFactor")
b = src.index("// MARK: - Kernel source")
twin = src[a:b]
# The twin's own helpers that the finish family calls (each up to the next helper).
for name in ("static func cbrt3(", "static func toLab(", "static func toRGB(", "static func lch(", "static func lab(", "static func wrapHue(", "static func hueDelta(",
             "static func smoothstep(", "static func gate(", "static func protectGate(", "static func membership("):
    i = src.index(name)
    eol = src.index("\n", i)
    line = src[i:eol]
    end = eol if line.rstrip().endswith("}") else src.index("\n    }", i) + 6
    twin += "\n" + src[i:end]
# Index arithmetic is not a constant: uniform slots, lane loops.
twin = re.sub(r"u\[\d+\]|e\(u, \d+|mul\(u, \d+|\.\.<\s*\d+|\[\d+\]|SIMD\d+", " ", twin)
glsl = subprocess.run([PROBE, "glsl"], capture_output=True, text=True, check=True).stdout
k = glsl.index("kernel vec4 lumenColourFinish")
body = glsl[k:]
helpers, seen, todo = "", set(), set(re.findall(r"\b(lumen[A-Za-z0-9]+)\(", body))
while todo:                                   # prelude helpers the kernel calls, transitively
    fn = todo.pop(); seen.add(fn)
    m = re.search(r"\n(?:float|vec3|vec4|bool) " + fn + r"\(.*?\n(?=(?:float|vec3|vec4|bool) |\Z)", glsl[:k], re.S)
    if m:
        helpers += m.group(0)
        todo |= set(re.findall(r"\b(lumen[A-Za-z0-9]+)\(", m.group(0))) - seen
NUM = re.compile(r"(?<![A-Za-z_0-9.])(\d+\.\d*(?:[eE][-+]?\d+)?|\d*\.\d+(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+|\d+)(?![A-Za-z_0-9])")
def lits(t):
    t = re.sub(r"//[^\n]*", "", t)
    return {round(float(x), 7) for x in NUM.findall(t)}
IGNORE = {0.0, 1.0, 2.0, 3.0, 0.5, 3.0e38, 1e-30, 1e-12, 1e-9, 0.25}
T = lits(twin) - IGNORE
G = lits(body + helpers) - IGNORE
only_t = sorted(T - G); only_g = sorted(G - T)
check("PAR-2", not only_t and not only_g, f"constants only in twin: {only_t}; only in GLSL: {only_g}",
      "both lists empty (every non-trivial literal of the twin's finish family appears in the GLSL finish kernel and vice versa)")
summary()
