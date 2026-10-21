"""Cut a full-width horizontal strip out of an LFI, keeping the long edge (so every long-edge-
denominated radius in the renderer is the same as for the whole frame).
usage: python3 lfi_strip.py IN.lfi OUT.lfi Y0 Y1      (rows Y0..Y1-1, full width)
       python3 lfi_strip.py IN.lfi --info              (print size)"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import read_lfi, write_lfi
a = read_lfi(sys.argv[1])
if sys.argv[2] == "--info":
    print(f"{a.shape[1]}x{a.shape[0]}"); sys.exit()
y0, y1 = int(sys.argv[3]), int(sys.argv[4])
assert a.shape[1] >= a.shape[0], "strip tool expects a landscape frame (width = long edge)"
write_lfi(sys.argv[2], a[y0:y1])
print(f"{sys.argv[2]}: {a.shape[1]}x{y1-y0} (long edge {a.shape[1]})")
