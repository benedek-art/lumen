# WS-18 / WS-17 verification (lane T3): round 1

Verifier, 2026-10-21. Subject: commit `5e515cf` on `quality/t3-sharpening`.

The lane's real base is `origin/claude/inspiring-dirac-ulgpch` = `9068ded`. The local branch
`claude/inspiring-dirac-ulgpch` is stale at `84bcd7c`, so `git diff claude/inspiring-dirac-ulgpch...HEAD`
also shows `866ba93`/`a93efb2`/`9068ded`: the UI snapshot workflow, PanelSnapshotTests and
LANE-BRIEF. None of those touch rendering. I reviewed `5e515cf` only.

Binaries:
- HEAD: release `lumen-render`. A rebuild was a no-op and gave the same md5, `85e8936e…`.
- Base: `/tmp/claude-0/ws18/base` at `84bcd7c`. It is render-equivalent to `9068ded`.

All numbers below are my own renders in `/tmp/claude-0/ws18/verify/`.

I could not run the unit tests. The debug test bundle is reserved, and running the existing
xctest binary was refused by the permission system. Lines that only a unit test holds are
re-measured through `lumen-render` where possible, and otherwise checked by reading the code.

**Working-tree note.** While I verified, the working tree held uncommitted edits to
`Tests/LumenCoreTests/Proof/ProofRegistry.swift`, `ProofFrames.swift` and
`SharpeningFrameTests.swift`:
- the sharpen sweep frames are swapped;
- the authority floors drop from 29/17/10/25 to `SharpenFloors` = 3/3/3/3.

This suggests the committed ProofRegistry sharpen sweeps fail at `5e515cf`. I did not verify
that, because I could not run tests. Those edits are not part of this commit.

## Spec lines

### Capture sharpening (S4)

Command: `measure_capture.py [--real] [--amount 150 --radius 2]`, plus a sweep script
(`/tmp/claude-0/ws18/verify/c5/sweep.py`) on the same edge.

| # | verdict | measured |
|---|---|---|
| C1 | PASS | σ1 slanted edge MTF50 0.2018 → 0.2810 (**1.392×**, needs ≥ 1.30). Zone plate 0.22 → 0.30 (**1.364×**, needs ≥ 1.20). |
| C2 | PASS | Amount 150, Radius 2: overshoot and undershoot **0.00 % / 0.00 %** on both the σ1 and the pristine edge. But see Break B2: the metric cannot see the failure this setting does have. |
| C3 | PASS | `flat_grey_noise` at ISO 6400: std ratio **1.000** at the matched profile and **1.000** at 1.6× the profile, at both defaults and 150/2. |
| C4 | PASS (proxy) | Blurred 4 px grating, display-linear modulation gain **1.985×**. The unit test was not run. |
| C5 | PASS (proxy) | 10–90 rise in px. Amount 25/50/100/150: 2.287 / 2.117 / 1.827 / 1.538, strictly falling. Radius 0.5/0.8/1.2: 2.267 / 1.827 / 1.483, strictly falling. The unit test was not run. |
| C6 | PASS (partial) | With `--iso`: capture off and Amount 0 give byte-identical PNGs. Without `--iso`: byte-identical to the base binary on 6 frames (see Breaks). The unit test was not run. |
| C7 | PASS (by inspection) | `out = image * exp2(d)` uses one scalar per pixel, so R/G and B/G are exact up to Float rounding. The unit test was not run. |
| C8 | NOT RUN | macOS. See the GPU review below. |
| C9 | PASS | Acutance gain: 6929_ivy **1.349**, 6929_canopy **1.231** (needs ≥ 1.10). 2348 wall std ratio **1.000** (needs ≤ 1.02). |
| C10 | NOT RUN (layout test) | Code read: there is a Radius row bound to `detail.capture.radius`. The panel strings say "Lumen default" and "Nothing is measured from the file". No string claims a measurement. |

### Creative sharpening (S12)

Command: `measure.py`. All runs share one scratch directory, so the "off" renders are shared.

| # | verdict | measured |
|---|---|---|
| S1 | PASS | `--check-identity`: Amount 0 is byte-identical to the default recipe on all 5 frames. |
| S2 | PASS | 2 EV edge MTF50 gain at Amount 40/70/100/150: 1.129 / **1.227** / 1.334 / 1.495, strictly rising. Zone-plate gain at 70: **1.202**. |
| S3 | PASS | 2 EV edge halo, bright/dark: A40 0/0 %, A70 0/1.04 %, A100 0/1.04 % (≤ 1.5). Blurred 1 px line ringing at A70: **1.65 %** (≤ 3). |
| S4 | PASS | Detail 0 at A70: 2 EV halo **0.00/0.00 %**, pristine 1 px line ringing **0.00/0.00 %**. Halo vs Detail 0/25/50/100 is monotone. The 2 EV edge reads 0 / 1.04 / 1.04 / 2.08, which rises but is flat between 25 and 50 (8-bit quantised). Blurred line: 0 / 1.65 / 3.31 / 6.61. Noise gain Detail 0 vs 100: 1.399 vs 1.592. |
| S5 | PASS | MTF50 gain at A70, Radius 0.5/1/2/3: 1.060 / 1.227 / 1.435 / 1.521, strictly rising. At Detail 100, Radius 0.5 gives 1.060 and Radius 3 gives 1.329. σ = radius × scale confirmed in code. ScaleHonestyTests was not run. |
| S6 | PASS | Detail 100 / A100, bright halo: **1.42 % → 0.57 %** at Damping 50 (−60 %) and **0.00 %** at Damping 100. Dark side 3.21 / 3.21 / 3.21. |
| S7 | PASS | Masking 50 noise gain: **1.003** at A70, **1.004** at A100. 2348 ISO 3200 wall, A100: std ratio **1.0001** at Masking 50 (1.0773 at Masking 0). 2 EV edge gain at Masking 50: 1.239 vs 1.227 unmasked (A70) and 1.339 vs 1.334 (A100), so ≥ 100 % kept. |
| S8 | NOT RUN (unit test / macOS view) | Code read: `maskPreview` uses the same `maskPlane` and knees as the render, and `SharpenMaskView` draws it on ⌥ + drag. |
| S9 | PASS | 6929 native full frame (7008 px, no `--iso`), A100: mean display-linear luminance shift **+0.0130 EV**. Base build: +0.0935. Default renders are byte-identical between head and base. |
| S10 | PASS (by inspection) | One ratio per pixel, multiplied into RGB. Pixels with c ≤ 1e-4 are untouched. The unit test was not run. |
| S11 | NOT RUN | macOS. See the GPU review below. |

### Visual claims

| # | verdict | notes |
|---|---|---|
| V1 | PASS, with a caveat | Capture on 6929_ivy is crisper. I saw no rim on any boundary at 100 % or 4×. The evidence sheet is downscaled, not 100 %, and the crop has no wall. At 4× the ivy's horizontal streak texture reads slightly "etched". |
| V2 | **FAIL** (jacket half) | The wires are crisper and the flat wall is unchanged, so that half holds. But the evidence sheet does not show the jacket. My 100 % / 2× crops of `2348_jacket` (defaults, ISO 3200) show many more isolated bright, coloured specks. Isolated bright pixels more than 40 codes above their 5×5 median go from **807 → 5 936** (more than 25 codes: 5 940 → 17 762). The fabric reads visibly grittier. See B1. |
| V3 | PASS | My full-frame 100 % crop (x 5360, y 880): the base A100 draws a grey rim inside every sky gap, and the head A100 is crisp with no rim. |
| V4 | PASS | My S7 render agrees with the sheet: wall std 1.0001 at Masking 50, and the wires look the same as at Masking 0. |

## Breaks found

**B1. S4 defaults amplify isolated bright pixels (noise and sparkle) on high-ISO texture, and brighten the crop.**
- Repro: `measure_capture.py --real` (defaults), then compare `2348_jacket_on.png` with `_off.png`.
- Mean linear luminance shift on the jacket crop: **+0.051 EV**. Dark pixels move −0.3 codes; pixels at 40–80 codes gain +4.8, and pixels at 80–140 codes gain +24.5.
- Speck count (pixels more than 40 codes above their 5×5 median):

| crop | off | on |
|---|---|---|
| jacket | 807 | 5 936 |
| canopy | 657 | 3 351 |
| ivy | 24 | 1 111 |

- At `--iso 6400` with Amount 150 / Radius 2, the jacket goes to +0.056 EV and std ratio 1.07. Classic NR luma 50 does not stop it (+0.037 EV, 1.06).
- Cause: textured fabric opens the gate. `peakAllowance` 1.0 then lets every one-pixel peak (including chroma-noise spikes riding on the weave) extend by its own height.
- No SPEC line covers capture-stage brightening or speckle. C3 only tests a flat field.

**B2. An oversized capture Radius softens and shifts sharp edges instead of ringing.**
- Repro: pristine slanted edge (`edge_b0`), `--iso 100`, Amount 100.
- MTF50 by Radius:

| radius | 0.8 | 1.2 | 1.6 | 2.0 |
|---|---|---|---|---|
| MTF50 (off = 0.615) | 0.738 | 0.648 | **0.566** | **0.486** |

  At Amount 150 / Radius 2 it is **0.508, gain 0.826**.
- The ESF shows the edge pushed about 0.4 px toward the bright side, with a wider rise. The 3×3 range clamp blocks overshoot, but it lets in-range ringing through. That erodes the bright side and closes small bright gaps; in my render of 1840's treeline at 150/2, sky holes in the canopy fill in.
- On the σ1 edge the gain already falls past Radius 1.6 (0.3395 → 0.3254 at 2.0). The zone plate at 150/2 gains only 1.091, against 1.364 at defaults.
- C2's overshoot metric is blind to this.
- The Radius tooltip says to lower it "if fine detail starts to look etched". The actual failure is softening and darkening.

**B3. S12 brightening exceeds the S9 bound on native crops and with Texture/Clarity.**
S9 passes on the full frame, where the sky dilutes the mean. On the native 6929_canopy crop (`--iso 250`, capture default):

| setting | linear mean shift |
|---|---|
| A100 | **+0.037 EV** |
| Texture 100 + Clarity 100, then A100 | **+0.074 EV** |
| same, Masking 50 | +0.069 EV |

At the extreme 150/3/100 on corpus frames treated as native: 4694 +0.108 EV, 1840 +0.083 EV. With capture 150/2 added: 4694 **+0.239 EV**, 1840 +0.214 EV.

**B4. S12 does nothing at a fit preview.**
- Repro: 4694 at `--long-edge 1200 --native-long-edge 8191`.
- Amount 150 changes **0 pixels**. The scale is 0.146, so σ = 0.146 and the taps degenerate to the identity.
- Capture is also off there (σ < 0.3, by design). At `--long-edge 2400` (scale 0.293), capture 150/2 changes 42 % of pixels.
- This follows S5's design, but it means every S12 slider is dead below about 30 % zoom. A human should decide whether that is acceptable.

**B5. Local Sharpness changed behaviour (outside the lane).**
- `RenderGraph.applyLocal` and `ReferenceRenderer`'s local stage now call S12 at decode scale 1.
- A masked Sharpness on a fit preview is therefore 1/scale wider in sensor terms than on export. Before this commit it was frame-denominated and consistent.
- This is acknowledged in NEEDS.md, but it is a preview/export mismatch the lane introduced.

**Other checks: no break found.**
- Black, white and NaN holes: none. On the synthetic stress frame (true black, 1e-4 shadows, 50.0 speculars, HDR 8–40, saturated colour, negative channels), `bw_step`, and 4694/1840/983 at extremes, I found 0 new pure-black pixels and 0 new pure-white ones. The only exception is 983 with capture + S12 extreme: 8 new white pixels.
- At Detail 100 the stress frame shows the expected unsharp-mask halos (an HDR patch ringed on white, and a bright rim on tomatoes and treeline). That is by design: Detail 100 is a free unsharp mask.
- Exposure +2 with capture default and A100: nothing new.

**Identity.**
- Default recipe without `--iso`: **byte-identical to base** on hard_edge, zone_plate, 4694, 1840, 983 and 6929_ivy at 1200 px.
- With `--iso 400`, the output differs by design, because S4 now runs:
  - display-linear mean shifts are within ±0.007 EV;
  - pixel changes reach up to 99 codes on the hard_edge AA row, where partial-coverage pixels are pushed dark.

## Code review

**GPU against CPU, line by line.** I found no arithmetic difference in either kernel.
- `deltaSource` and `lumenSharpenRatio` reproduce `peakBounds` exactly: the same four directions, the same one- and two-pixel peak terms, and the same clamp order (gate × strength first, then the bound).
- S12 matches too: the free value, then the bound, then halo damping applied only to positive overshoot, then detail, then the mask, then the cubed ratio clamped to [1/4, 4], skipped when c ≤ 1e-4.
- The taps are the same Floats. `gauss13` covers ±6. `box3` ×3 equals `boxApproximatedGaussian(1.5)`, which an existing test pins.
- VST: the recentred form `2(y−x0)/(√u+√u0)` differs from `(2/a)√u` only by a constant, so its gradients are identical, including the a → 0 branch. The u ≤ 0 branch cannot occur, because luminance is floored at 0.
- Reach and ROI are right: 6 for the Gaussian, 1 for the gradient and box, 2 for delta and ratio. All neighbourhood inputs are `clampedToExtent`.
- The stage is symmetric under a y-flip: the direction set {(1,1), (1,−1)} and the central differences are both symmetric.
- Decode scale comes from `sqrt(noiseScale)`, which is right at every `graph.build` site; export uses 1.

**Half-float hazards.** None are covered by the f16 parity tests:
- Both parity fixtures skip pixels below 1e-3 and stay at or below about 0.64 linear at ISO 1600.
- The capture `delta` kernel takes `log2` of half-float luminance down to a floor of 1e-6, which is subnormal in f16. Deep-shadow behaviour on the GPU is therefore untested.
- At ISO 100 the VST plane reaches about 1000 at y = 4 and about 1500 at y = 8, where the f16 step is 0.5–1.0 noise σ. That is low risk against knees at 2.5σ, but untested.

**Fallback paths.**
- If any S4 kernel is missing, S4 silently becomes the identity on the GPU while the CPU still runs it. This is stated in the code, and a parity test asserts the kernels compile.
- The S12 fallback is a per-channel `CIUnsharpMask` with radius = σ, so it can shift hue. It is documented.
- `KernelLibrary.sharpenDelta` is still on the core roster and compiled, but nothing calls it. The SharpenGPU.swift header says "other goldens still read them"; `grep` finds no test that does, so that sentence is false.

**Changes outside the sharpening functions:**
- `AppleRawSource`: `sharpnessAmount = 0`, and the strength removed from the decode key.
- `ReferenceRenderer`: the S8 decomposition condition, and `Inputs.decodeScale`.
- `RenderPlan.capture`.
- The `PipelineRenderer` CPU fallback.
- CLI, main and RecipeKeys: `--native-long-edge`. This also changes the scale S3 is told.
- AppState, LoupeView and the new SharpenMaskView (⌥-drag).
- LayoutMetricSupport: the slider count and line numbers.
- Indirectly, local Sharpness (B5).

**Dead code left behind:**
- `DetailEngine.applySharpen(decomposition:)` takes an unused `decomposition` parameter.
- `RenderGraph.fineDetailBand` has no caller.
- `SpatialOps.fineDetailBand` and `fineBandLevel` are only called by each other or by dead code.
- `SpatialOps.estimatePSFSigma` is only used in tests.
- `SpatialOps.richardsonLucy` has no caller.
- `ManualSharpen.unsharpRadius` is only used in tests; the fallback no longer reads it.
- The `sharpenDelta` kernel.
- `DetailPanel.captureAmountHelp`'s `isRenderedFile` branch, which the code itself admits is unreachable.

**Comments that are now false:**
- `Recipe.swift` `CaptureSharpen`:
  - "auto-radius RL deconvolution";
  - `radius` "nil = auto-estimated" (it is now a fixed 0.8);
  - "A NaN here would reach `sharpnessAmount`".
- `Recipe.swift` `ManualSharpen.unsharpRadius`: the doc block says the GPU path uses `CIUnsharpMask` as the fallback radius.
- `DetailPanel.swift` around line 100: "fields whose ONLY reader is `AppleRawSource`".
- DetailPanel tooltips: "Capture sharpening happens inside / is part of the raw decode" (lines 148, 251, 275). S4 now runs after S3.
- `ReferenceRenderer.swift` around line 488: negative Sharpness "at the same 2560 px reference as positive sharpening".
- `SpatialOps.swift` around line 406: "S12's radius all mean 'this much AT 2560 px'".
- `measure.py` header: S12's sigma is frame-denominated (already known).

**Tests loosened rather than corrected:**
- `FieldBaselineProbeTests.testHaloSuppressionDampsTheRimItExistsToDamp`: the "mechanism runs" floor drops from 0.01 to 0.005. The main assertion was strengthened (Equal flipped to LessThan), and the reason is given.
- `SharpenStageTests` S7 asserts the edge keeps > 80 % of its gain, while SPEC S7 says ≥ 90 %. The script measured ≥ 100 %.
- `ScaleHonestyTests.testSharpeningMeansTheSameFractionOfThePictureAtEitherRenderSize` was deleted and replaced by the opposite contract. That is a deliberate design reversal (S5), not a loosening.
- Uncommitted, not in this commit: the ProofRegistry sharpen floors drop from 29/17/10/25 to 3/3/3/3. That is a loosening by a factor of 3–10 and needs the reason stated if it is committed.

## Verdict: **FAIL**

Every SPEC line I could run passes, with the number. The verdict is FAIL because:
1. V2 does not hold. At default settings (S4 is on for every RAW), the ISO 3200 jacket gets visibly grittier, with about 7× the isolated bright specks, and the crop brightens by 0.05 EV (B1).
2. An oversized capture Radius softens and shifts sharp edges (B2), and no spec line catches it.
3. S12 brightens by 0.04–0.07 EV on native foliage crops and with Texture/Clarity (B3). That is outside the 0.02 EV that S9 states only for the full frame.
4. Dead code and false comments remain, and the Linux gate (ProofRegistry sweeps) at `5e515cf` is unverified. In-flight test edits suggest those sweeps fail.

For the builder:
- Add a speckle/brightening line for S4: a mean-shift bound and a cap on peak allowance under the noise profile.
- Add a pristine-edge MTF ≥ off check across the whole Radius range.
- Delete the dead helpers and fix the stale comments.
- Commit the ProofRegistry changes with measured floors and the reason for each.

---

# Round 2

Verifier, 2026-10-21. Subject: local HEAD `1e7f7d6` (`dd96ed7` + `1e7f7d6` on top of `5e515cf`).

Binary: the release `lumen-render` in this tree was linked at 03:36, before the final edit to
`CaptureSharpening.swift` at 03:37. I waited until the coordinator's release `swift test` build
relinked it (03:41:34) and copied it to `/tmp/claude-0/ws18/verify/r2/lumen-render`
(md5 `a1625edb…`). All round-2 numbers come from that copy.

I ran no build and no tests myself.

## Spec lines, re-measured

### Capture (S4)

| # | verdict | round 2 (round 1) |
|---|---|---|
| C1 | PASS | Edge **1.393×** (1.392). Zone **1.364×** (1.364). |
| C2 | PASS | 150/2: 0.00/0.00 % on σ1 and on pristine. B2 is still open, see below. |
| C3 | PASS | **1.000** matched, **1.000** at 1.6× (defaults and 150/2). |
| C4 | PASS (proxy) | Grating gain **1.985×**, unchanged. |
| C5 | PASS (proxy) | Rise for Amount 25/50/100/150: 2.287/2.117/1.827/1.538. Radius 0.5/0.8/1.2: 2.267/1.827/1.483. |
| C6 | PASS (partial) | Capture off and Amount 0 are byte-identical. Without `--iso`, byte-identical to base on hard_edge, 4694, 1840, 6929_ivy and the 6929 native full frame. |
| C7 | PASS (by inspection) | Unchanged. |
| C8 | NOT RUN | macOS. See the kernel review below. |
| C9 | PASS | Ivy **1.281** (1.349). Canopy **1.211** (1.231). Wall std **1.000**. |
| C10 | NOT RUN (layout test) | Panel strings read; no measurement claims. |
| **C11** | **PASS** | `2348_jacket`, defaults, ISO 3200. Specks more than 25 codes above their 5×5 median: **5 940 → 6 655 = 1.12×** (≤ 1.2). Mean shift **+0.0099 EV** (≤ 0.02). In round 1 the same metric read 2.99× and +0.051 EV. |

On C11:
- My OFF count differs from the builder's (5 940 vs 6 345), but the ratio agrees (1.12 vs 1.11).
- At a 40-code threshold the jacket still reads 807 → 1 694 (2.1×). That is 0.16 % of pixels, and it does not show at 2× zoom.

### Creative (S12)

The S12 code did not change. Every metric re-ran **bit-identical to round 1**, across 17 measure.py configurations.

| # | verdict | round 2 |
|---|---|---|
| S1 | PASS | Identity holds on all 5 frames. |
| S2 | PASS | 1.129 / 1.227 / 1.334 / 1.495. Zone 1.202. |
| S3 | PASS | Halo at A ≤ 100 is at most 0/1.04 %. Blurred line 1.65 %. |
| S4 | PASS | Detail 0: 0/0 %. Monotone in Detail. Noise 1.399 vs 1.592. |
| S5 | PASS | 1.060 / 1.227 / 1.435 / 1.521. At Detail 100: 1.060 vs 1.329. |
| S6 | PASS | 1.42 → 0.57 → 0.00 %. Dark side 3.21 throughout. |
| S7 | PASS | Noise 1.003 / 1.004. Wall **1.0001**. Edge keeps ≥ 100 %. |
| S8 | NOT RUN | Unchanged. |
| S9 | PASS | **+0.0130 EV**. The A0 render is byte-identical to base. |
| S10 | PASS (by inspection) | Unchanged. |
| S11 | NOT RUN | macOS. |

### Visual

| # | verdict | notes |
|---|---|---|
| V1 | PASS | The regenerated sheet is crisper than off. My crops show no rims. |
| V2 | **PASS** (was FAIL) | The sheet now includes the jacket. My 2× crop of the jacket (round 1 vs round 2 vs off) shows round 2 indistinguishable from off for grain. The wires are still crisper than off at 3×, though the wire crop's acutance proxy is now only 1.008 (1.034 in round 1). |
| V3, V4 | PASS | Unchanged. |

## GPU kernel diff (`lumenCaptureDelta`), checked against `CaptureStage.clampedDelta`

New uniforms: `shot` = `profile.a`, `read` = `profile.b`, `sigLo` = 8, `sigHi` = 16. They are passed in the order the kernel declares, all as `Float`.

| GPU | CPU | match |
|---|---|---|
| `yc = max(lum, lumFloor)` | `observed` floored at 1e-6, the same as `noiseLog2Sigma`'s `max(y, logFloor)` | yes |
| `sigma = sqrt(max(shot·yc + read, 1e-12)) / (yc·ln2)` | `profile.sigma(at:)` = `sqrt(max(a·y + b, minimumVariance = 1e-12))`, divided by `y·ln2` | identical |
| smoothstep on `up` and `dn` separately, then the bound `mn − allowance·wDn·dn`, `mx + allowance·wUp·up` | `peakExtents` followed by the same weighted bound | identical |

The kernel's float math is f32 even in the RGBAh working format. At the 1e-6 floor, σ is huge and the weight is 0 in both renderers. The reach is still 2. The `scaled(decodeScale:)` profile reaches the GPU through `stage.profile`, as it does on the CPU.

**Stale comment.** The `deltaSource` doc says the peak "stands **3–6** noise σ clear". The constants are 8/16.

## Round-1 items

| item | status |
|---|---|
| B1 | **Fixed**, see C11. Trade-off: ivy acutance 1.349 → 1.281, jacket acutance 1.306 → 1.035 (S4 now barely sharpens the ISO 3200 fabric). |
| B2 | Behaviour unchanged. My re-run at 150/2 gives pristine edge MTF50 gain **0.826** and zone plate 1.091, the same as round 1. The coordinator says the Radius tooltip now names this failure. **It does not:** `DetailPanel.swift:231-234` at `1e7f7d6` still reads "…lower it if fine detail starts to look etched." No commit after `5e515cf` touches that string. The known limit is therefore stated nowhere in the shipped product yet. |
| B3, B4, B5 | Unchanged. Accepted as owner judgements. |
| `sharpenDelta` | Deleted from source and roster. No references remain. |
| Stale comments | Fixed in Recipe.swift (CaptureSharpen), the DetailPanel tooltips and the reader comment, `SpatialOps.frameDenominatedSigma`, ReferenceRenderer's local-sharpness note and the SharpenGPU header. |
| Dead code | Remaining dead code (`fineDetailBand`, `estimatePSFSigma`, `unsharpRadius`, the unused `decomposition` parameter) is either stated in the SharpenGPU header or test-pinned. Acceptable. |

## Proof-registry floors

Amount 29 → **18**, radius 17 → **19**, masking 10 → **19**, halo 25 → **19**.
- The frames changed with them: a σ1 soft step for amount and radius, Detail 100 for halo, texture plus a noise ramp for masking.
- The reason is stated next to the floors.
- Amount and halo floors went down, but each is measured on a frame where the new stage has something to do, and both stay above docs/20's 2.9 bar.

I accept this as a corrected test, not a loosened one. I did not run it; the coordinator's release run of ControlProofTests is the evidence.

`SliderEvidenceTests` moves capture Amount and Radius from a macOS-only disposition to contracts on `CaptureStageTests`, which is consistent with the new S4.

## Round-2 verdict: **PASS**

Every Linux-runnable SPEC line passes with the number, including the new C11, and V1–V4 hold.

Two documentation defects remain. Neither is a SPEC line:
1. The capture Radius tooltip does not name the over-correction failure, although the builder's summary says it does.
2. `lumenCaptureDelta`'s doc says 3–6σ where the code uses 8/16.

Both are one-line fixes and should land before merge. B2 itself (an oversized Radius softens sharp edges) goes to the report as a known limit.

The NOT RUN lines need macOS CI: C8, S11 (GPU parity, including the new uniforms), C10 and S8.
