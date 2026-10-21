# WS-35 / WS-36 (lane K1): changes needed outside this lane

1. **DisplayTransform (S14) hue skew on blues.** A wheel tint's OKLab hue lands within
   0.2–3° of the wheel angle everywhere except 210–270°, where the display transform
   turns it +6…+8° toward purple before it reaches the screen (measured on the grey
   ramp; `evidence/measure-after.json`, `hue_accuracy_sat1`). `DisplayTransformParams
   .rotation` documents this as a known defect (blue primary rotated the wrong way, kept
   for the 65-cube tracking reason). The grade cannot correct it without baking a
   display-specific inverse into a scene-referred stage. Owner: the display-transform
   lane.
2. **Global Luminance +1 on saturated colours.** The wheel's brightness move holds
   working-space hue to < 1° (unit test), but at +1 (≈ +1.5 EV on neutrals) a saturated
   orange patch reaches the display shoulder and turns 9.4° there; Exposure +1 alone turns
   the same frame's patches 5.8°. Path-to-white behaviour, same owner as 1.
3. **`LumenSlider` focus surface.** In `panel-grade-grading.png` (baseline) the first
   focusable slider under the wheel wore its keyboard-focus fill in the snapshot, which
   is part of why the bar looked "boxed". Lane K1 replaced that bar with aligned rows; if
   the snapshot harness gives initial focus to the first slider in every panel, other
   panels will show the same fill. Owner: U2 (`LumenSlider`).
