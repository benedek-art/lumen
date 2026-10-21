# WS-30 Creative LUT: acceptance spec

Owned: `CreativeLUT.swift`, `RG.applyCreativeLUT`, `LookPanel.lutSection`/`lutAmountBinding`,
`LUTReference`. Test cubes are generated from closed-form functions by
`tools/lutref.py gen` (identity 17/32/33/65, `contrast709` a logistic S-curve with a 15%
Rec.709-luma pull, `logcontrast` 1.25x about grey in LumenLog, `twist` a size-9
non-linear hue twist, `log2709` a camera-style LumenLog/Rec.2020 → sRGB/Rec.709 transform).

Reference: `tools/lutref.py check` (numpy, written from the declared spaces, its own
tetrahedral AND trilinear interpolants, its own CIEDE2000) against the stage via the
scratch `lutprobe` binary; `Tests/LumenCoreTests/CreativeLUTAccuracyTests.swift` is the
Swift twin that runs in CI. ΔE is CIEDE2000 on the sRGB preview code (the log tap through a
fixed `x/(x+0.18)` view).

The contract being specified (both renderers):
- display: `d = W2D·x; u = clamp(d,0,1); e = srgb(u); b = max(e + a·(L(e) − e), 0); out = D2W·(srgb⁻¹(b) + (d − u))`
- log: `e = LumenLog(x); u = clamp(e,0,1); out = LumenLog⁻¹(e + a·(L(u) − u))`

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| L1 | Identity cube (17, 32, 33, 65) at either tap, Amount 37/100/200, is the identity on every value incl. Rec.2020 outside sRGB, EDR to 3× white, scene −10…+8 EV | max error < 1e-6 (display: linear; log: LumenLog code); < 1e-12 for sizes with exact knots | `CreativeLUTAccuracyTests.testL1…`, `lutref.py check` |
| L2 | `contrast709` 33³ at the display tap, Amount 0/25/50/100/150/200 | max ΔE2000 < 0.5 vs reference | `testL2…`, `lutref.py` |
| L3 | `logcontrast` 33³ at the log tap, Amount 0…200 | max ΔE2000 < 0.5 | `testL3…`, `lutref.py` |
| L4 | Amount is linear in the cube's own encoding over 0…200; clamps at 0 and 200; NaN reads 0; 200% never goes below black or non-finite | encoded error < 1e-9 per 10% step | `testL4…` (two tests) |
| L5 | Interpolation is tetrahedral (not trilinear) | barycentric 4-corner mix to 1e-7; differs from trilinear by > 0.01 | `testL5…`; `lutref.py` twist_9 ΔE(tetra) = 0 |
| L6 | Out-of-domain values keep their residual: the change to a P3 red / 2.5× white equals the change at the nearest in-domain value | < 1e-9 | `testL6…` |
| L7 | A camera log-to-709 LUT renders as its author intended | mean ΔE < 2 vs reference | `evidence/lut-log2709-both-taps-wrong.png` |
| L8 | GPU graph matches the reference stage | existing `CreativeLUTParityTests` bounds (macOS CI) | `gpu-parity.yml` |

Visual claims:
- V1 `evidence/lut-contrast709-amount-0-200.png`: equal visual steps from 0 to 200, 200 strong but not clipped or posterised.
- V2 `evidence/lut-log2709-both-taps-wrong.png`: shows why L7 cannot pass with the current two taps.
