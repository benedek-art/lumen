# M8 report: WS-53 local presence & sharpness, WS-54 local curve, WS-55 local noise/moiré/defringe/grain

Branch `quality/m8-local-presence` from `claude/inspiring-dirac-ulgpch` (9068ded). Audit:
`AUDIT.md`. Spec: `SPEC.md` (committed before code). Requests to other owners: `NEEDS.md`.
Verifier: independent agent, **PASS** (numbers below are the verifier's own re-measurement).

## For the owner

1. Local Noise and Colour Noise now render (both renderers, through the classic NR engine); Moiré, Defringe and Grain stay hidden because there is no engine to back them.
2. Local Sharpness now uses your global Radius/Detail/Masking; before, it ignored them (up to 50 codes off). Negative Sharpness no longer has a dead first quarter.
3. Like global NR, local Noise shows nothing at fit view (preview scale ≤ 0.71). Judge it at 1:1, or you'll think the slider is dead.
4. Try by hand: Colour Noise over default global chroma 25 does most of its work by 25 (D4 below). Tell me if that feels wrong.
5. Not built: Lightroom's negative Noise (cancel global NR) and negative Sharpness fading global sharpening. Both need another lane's stage (NEEDS 5, 8).

Best evidence: `evidence/sharp_neg_fence.png` (0/−10/−25/−50/−100, each visibly softer),
`evidence/noise_g9_core.png` (ISO 3200 G9 at 100 %, none vs local Noise 70),
`evidence/edge_6929_dehaze.png` (feathered radial, Dehaze ±100, no rim).

## Verdict per spec line

| # | Claim | Result | Measured |
|---|---|---|---|
| 1 | Full-frame local Texture/Clarity/Dehaze = global | PASS | 132/132 pairs, 11 images, ±50/±100: max 0 codes |
| 2 | Full-frame local Sharpness = global Sharpen at user's r/d/m/h | PASS | max 0 on 2545, 6929, zone_plate (base: max 20–36, mean 1.6–4.8 at 1024; 50 at native) |
| 3 | Negative Sharpness responds from the first step | PASS | m(−10…−100) = 5.40, 8.32, 10.45, 11.60, 12.36; ratios 0.44, 0.67 (need 0.15, 0.35). Base m(−10) = 0.003 |
| 4 | No seams/halos at the edge | NOT MET as written, pre-existing | 54 cases: outside 0, core 0, feather 0.00 % in 53; 1569 Sharpness −100 is 0.01 % (71 px, ≤ 5 codes), byte-identical to base (saturated blue/cyan through the display transform) |
| 5 | Local curve = global curve | NOT MET at lut 33, pre-existing | lut 65: ≤ 2 in 35/35. lut 33: 11/35 over 3 (4–7). All 70 renders byte-identical to base: the error is the global finish table's (NEEDS 15) |
| 6 | Defaults are an exact identity | PASS | 4 variants on 2348 native with global NR + sharpen: same MD5 |
| 7 | Local Noise/Colour Noise = the global engine | PASS | unit tests ≤ 1e-5; CLI: full-frame local 100/100 byte-identical to global luma/chroma 100 |
| 8 | Profile follows exposure | PASS | (4a, 16b) at +2 EV; local exposure ±3 + Noise 50 byte-identical to global equivalent |
| 9 | NR only inside the mask, monotonic | PASS | G9 high-pass σ 1.657 → 0.920/0.582/0.404/0.303 at 25/50/75/100; outside 0 codes |
| 10 | Preview rule same as global | PASS (CLI + reference); app CPU fallback pending NEEDS 2 | identity at scale² ≤ 0.5, acts above, both local and global |
| 11 | Moiré/Defringe/Grain unrendered, unoffered, round-trip | PASS | `MaskDeadFieldTests` keeps those three rows |
| 12–13 | Documented, not fixed | NEEDS 3, 9, 10 | |
| 14 | CPU+GPU together, build, tests | PASS | builds clean; full LumenCoreTests (620 runs, class by class, release) EXIT 0, base also 0 |

Visual: V1 PASS (core cleaner, weave softened as expected at 70, no feather edge), V2 PASS,
V3 PASS.

## Part 2: what each dead control became, and why

- **Noise: implemented, 0…100.** Lightroom's most-used mask detail control after
  Sharpness. Runs at S11 through `ClassicalDenoise` with the global Detail/Contrast/
  Smoothness and the S3 noise profile carried to the S11 signal level (g·a, g²·b, g =
  global × mask exposure gain). One-sided: Lightroom's negative half (remove global NR
  in the mask) needs the image before S3, which S11 does not have (NEEDS 5).
- **Colour Noise: implemented, 0…100.** Lightroom has no local chroma NR, but it is the
  same engine pass at no extra cost and fixes the colour blotches a local Shadows lift
  exposes, without blurring colour across the frame.
- **Moiré: left out of the UI.** No global moiré engine exists. A slider wired to
  nothing is exactly the bug this lane removes.
- **Defringe: left out.** The global defringe (lane C3) does not render yet;
  `MaskDeadFieldTests` fails the day it does, so the local half gets picked up.
- **Grain: left out.** Lightroom masks have no Grain (I'm fairly sure, not certain).
  Grain is a whole-frame film property, and the stock vs creative amplitude
  normalisation is unsettled (WS-40). The field stays carried so no recipe loses data.

## What changed

- `Sources/LumenCore/Engine/LocalNoise.swift` (new): the one place the local engine and
  its profile are built; both renderers call it.
- `ReferenceRenderer`: local NR before presence; `localSharpen` (global settings, local
  amount) and `localSofteningRadius` (2.5·√t) as shared helpers; `Inputs.noiseScale`,
  passed through `applyMasks` (one-line touch of WS-01's call, NEEDS 1).
- `RenderGraph`: `applyDenoise`'s body extracted verbatim into
  `applyClassicalDenoise(_:engine:noiseScale:)` (T4's function, arithmetic unchanged,
  NEEDS 4) so local NR runs the same kernels; local sharpness uses the shared helpers.
- `MaskPanel.detailSection`: Noise and Colour Noise rows after Dehaze, before Sharpness
  (render order: NR before sharpening). `RecipeMasks`: comment block rewritten (D6 fixed),
  noise fields join `Group.detail` for the dot and Reset.
- CLI passes the decode scale. Tests: `LocalNoiseTests` (8), `LocalPresenceTests` (5).

Existing tests changed and why: `MaskDeadFieldTests` lost the noise/noiseChroma rows
(they render now, which is what that test exists to catch). `LocalAdjustGroupTests`
moves them into `.detail` (count 4 → 6). `LayoutMetricSupport` gets the two new rows and
the six citations the insertion moved. `LocalSofteningScaleTests` sweeps −25 instead of
−50 so it still crosses σ = 1 under the √t radius.

## Open, for a human or another lane

- **D4 (judge by hand):** local Colour Noise over default global chroma 25 is front-loaded.
  σ_chroma 0.55 at local 25, 0.49 at 100. Negative Sharpness −50…−100 adds ~2 codes mean.
  The local pass thresholds against the full sensor profile (NEEDS 6).
- **D1 (verifier):** `PipelineRenderer.renderReference` (CPU fallback) does not pass the
  noise scale yet, so local Noise acts on fallback previews where the GPU skips it (NEEDS 2).
- **D3 (pre-existing, blend lane):** luminosity-blend masks with any spatial op leave
  magenta fireflies on near-black pixels (base: 3924 px > 40 codes at Sharpness −100).
- Full-frame local Dehaze/Clarity drift from global once global colour/grade is edited
  (local runs after S9/S10; NEEDS 3).
- GPU and SwiftUI code could not be compiled here; read line by line by the verifier.
  macOS CI is the check.
