# WS-51/52 needs from other lanes

## WS-42 (`RG.compositeLocal`, `ReferenceRenderer.applyMasks` composite): hue through the feather

The composite mixes the adjusted and original pictures in scene-linear RGB by alpha. For
every control on this lane that is smooth and halo-free (SPEC F1-F3). The exceptions are
edits that move a colour toward its complement. White-balance Tint +100 over foliage
(green toward magenta) is one: on 6929 / 2545 it measured an L* ring of 1.8 / 2.6 and a
C* dip of 13.3 / 9.4, and Tint +50 a dip of 6.9 / 8.3. That is the same before this lane's
change (Tint +100: L* 2.6, dip 12.3 on the old binary). The other is a large local Hue rotation: at alpha 0.5 a +180° turn mixes a colour with its complement
and the feather passes through grey. Measured, radial r 0.3 feather 60, `measure.py
feather <lfi> FULL 'hue=180'`: C* dip p99 16.6 (A7 IV 6929) and 13.2 (GX85 2545), against
1.7 at Hue +60. A parameter-scaled feather (which is how I understand Lightroom's
masks to behave; not verified against a reference export) would turn the hue part way
instead of greying it. Ask: for a mask whose only colour edit is a hue rotation
(or generally), composite chroma in polar OKLCh (mix L and C linearly, h along the short
arc) instead of RGB. Not done here because the composite is WS-42's.

## Picture formation / gamut (S14 owner): output lightness moves under a constant-Y chroma ramp

Local Colour tint holds scene luminance Y exactly. Yet sweeping Strength 0→100 toward an
sRGB-blue swatch on GX85 2545 moves the mean OUTPUT L* 37.4 → 39.7 (Strength 25) → 37.5
(Strength 100): a +2.3 L* bump at mid chroma that returns at full chroma. Inside a
feathered mask that bump is a lighter ring (L* p99.9 5.4, SPEC F4). An OKLab-L-holding
tint was tried and measured the same (5.9), so it is not the tint's construction. Ask:
check the display transform's chroma compression / H-K handling for non-monotone
lightness along a constant-Y chroma ramp.
