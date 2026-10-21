"""Gain of a whole frame: regression of log2 Y(render) - mean onto log2 Y(identity) - mean, 4 px border
trimmed. Used for the G2b probe-content check and anything else with one pattern per frame.
usage: python3 probe_gain.py DIR PREFIX [name ...]"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, gain
d, p = sys.argv[1], sys.argv[2]
r = logY(load(f"{d}/{p}_id.png"))[4:-4, 4:-4]
out = []
for n in sys.argv[3:] or ["t-100", "t100", "c-100", "c100"]:
    fn = f"{d}/{p}_{n}.png"
    if os.path.exists(fn):
        out.append(f"{n} {gain(logY(load(fn))[4:-4, 4:-4], r):.3f}")
print(f"  {p}: " + "  ".join(out))
