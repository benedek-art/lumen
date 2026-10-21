#!/usr/bin/env python3
"""Write the WS-41 synthetic frames to $WS41_OUT/frames (3:2 unless noted, scene-linear
Rec.2020, neutral = R=G=B). Same content as the audit's mkframes.py plus a checker.

  flat32   1536x1024 flat 0.18
  skytest  sky (0.35,0.55,0.95) top 40%, white 1.5 patch TL, specular 4.0, snow 0.6 bottom band
  colour4  red / blue / green / skin quadrants
  checker  2-stop checker (0.09 / 0.36), 16 px squares -- corner contrast for Paint Overlay
"""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import FRAMES, write_lfi

os.makedirs(FRAMES, exist_ok=True)
W, H = 1536, 1024
write_lfi(os.path.join(FRAMES, 'flat32.lfi'), np.full((H, W, 3), 0.18))
a = np.full((H, W, 3), 0.18)
a[:int(H * .4)] = [0.35, 0.55, 0.95]
a[20:120, 20:120] = 1.5
a[150:200, 20:70] = 4.0
a[H - 200:] = 0.6
write_lfi(os.path.join(FRAMES, 'skytest.lfi'), a)
b = np.zeros((H, W, 3))
b[:H // 2, :W // 2] = [0.40, 0.06, 0.04]; b[:H // 2, W // 2:] = [0.10, 0.20, 0.45]
b[H // 2:, :W // 2] = [0.08, 0.25, 0.06]; b[H // 2:, W // 2:] = [0.40, 0.22, 0.15]
write_lfi(os.path.join(FRAMES, 'colour4.lfi'), b)
y, x = np.mgrid[0:H, 0:W]
chk = np.where(((x // 16) + (y // 16)) % 2 == 0, 0.09, 0.36)
write_lfi(os.path.join(FRAMES, 'checker.lfi'), np.repeat(chk[..., None], 3, 2))
print('frames ->', FRAMES)
