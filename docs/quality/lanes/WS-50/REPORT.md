# WS-50 mask refine chain + WS-43 component algebra: report (lane M6)

Branch `quality/m6-mask-refine`. Spec: `SPEC.md`. Things other lanes must do: `NEEDS.md`.
Tools to reproduce every number: `tools/` (see `tools/README.md`).

## For the owner

1. Expand was broken on any textured mask (colour/luminance range): pixels flipped the wrong way, rings and torn stripes. Now it's a real grow/shrink: monotone, no new speckle, 3× faster.
2. Follow now reads colour as well as brightness, so it stops dragging equally bright background (twigs behind a red can) into the selection. Leak is down 56%.
3. Subtract is wrong in a way you'd notice: a soft subtract over a soft area often removes nothing. Intersect at Amount 0 wipes the whole mask. Fixes are written up in NEEDS.md; they need WS-42 and the GPU lane.
4. Decide: Expand now grows faint 0.2 speckle into grey octagons too (2545 sky: coverage 0.06 → 0.31 at +25). Correct maths, may read as bubbles. See "Not fixed".
5. No refine control removed. All six measure as doing something distinct (table below).

## Verdict per spec line

Corpus numbers at 2400 px long edge, CPU definition, before = base `9068ded`, after = this branch.

| # | claim | before | after | verdict |
|---|---|---|---|---|
| R1 | defaults are exact identity | holds | bit-identical (`testDefaultsAreAnExactIdentity`) | PASS |
| R2 | Expand per-pixel monotone | worst wrong-way step **1.000**; 2.9 % (RsC), 13.2 % (C), 9.1 % (LiU) of pixels | **0** at every integer Edge −50…50 on C, LiU, 6929 luma, 2545 luma (round 2, after the border fix); ≤ 1e-6 on unit fixtures incl. border | PASS |
| R3 | Expand makes no speckle | Edge 0 → worst Edge≠0: RsC 313 → 1602, C 708 → 3493, LiU 990 → 4021 | RsC 313 → 98, C 708 → 228, LiU 990 → 237, hardR 0 → 0 | PASS |
| R4 | boundary moves by the shift | hard/soft ±1.5 px held | hard/soft ±1.5 px held; full travel 40 px asked → within 6 % (axis 38.7 px) | PASS |
| R5 | profile kept | soft radial rose 0.33 % under erosion (documented residual) | erosion raises no pixel (> 1e-6); mean distance to exact disc < 0.01 at ±50 | PASS |
| R6 | density and hardness kept | 4 tests pass | same 4 tests pass unchanged | PASS |
| R7 | Follow follows colour | off-hue leak at Follow 100: 11.7k | 5.2k (44 %) | PASS (see note) |
| R8 | Follow visible at 10 | max change 0.69–1.00 | 0.70–0.81 | PASS |
| R9 | Soften blurs without moving | drift ≤ 0.053 %, stair monotone, 1 small component | identical (Soften untouched) | FAIL as written (see note) |
| R10 | Ramp from/to/shape monotone, non-redundant | wrong-way 0; γ = 2 best from/to fit within the slider range misses by 0.081–0.107 (an unconstrained fit, outside the slider range, gets to 0.024) | unchanged | PASS |
| R11 | finite, inside [0, 1] | held | held (`testWholeChainStaysInRange`, NaN/inf settings included) | PASS |
| R12 | Expand not slower | 0.34 s (radial, 2400 × 1600, Edge 50, minus raster) | 0.10 s | PASS |
| A1 | CPU fold = MaskAlgebra (max / min(a, 1−v) / a·v) | max \|Δ\| 0 | 0 | PASS |
| A2 | subtract removes partial overlap | 26 % of overlap pixels untouched | unchanged | **FAIL → NEEDS N1** |
| A3 | `R − C` = `R ∩ ¬C` | max \|Δ\| 0.242 (8559), 0.250 (983) | unchanged | **FAIL → NEEDS N1** |
| A4 | Amount 0 is identity for every op | add, subtract exact; intersect max \|Δ\| **1.0** (mask emptied) | unchanged | **FAIL → NEEDS N2** |
| A5 | references and nested inverts exact | max \|Δ\| 0 on 4 combinations | 0 | PASS |
| A6 | invert before refine | test passes | passes | PASS |
| V1 | `expand_8559_colour.png` coherent | rings, bubbles, stripes | one shape growing/shrinking | PASS |
| V2 | `follow_8559_colour.png` twigs stay out | twigs selected from Follow 50 | twigs stay dark | PASS |
| V3 | `algebra_8559.png` shows the subtract dead zone | n/a | engine subtract: flat 0.5 plateau over the partly matched can; same selection as intersect-inverted: graded; Intersect@0: empty | evidence for N1/N2 |

**R7 note.** My first leak metric counted any pixel with OKLab ΔE > 0.15 from the sample, and on that it read 19.3k vs 27.0k (71 %), a fail. Looking at what it counted: mostly the can's own shadow side (same hue, lower L), which Follow is right to add. I changed the metric to hue (> 60° from the sample, chroma > 0.03) before re-measuring, and say so here because it was changed after seeing a number. Restricted to the can region, the colour guide cuts the leak 4× (1.3k vs 5.2k).

**R9 note.** The spec says 0 components and I measure 1, so it fails as written. That one component, at Soften ≥ 25 on C and RsC, is a single pixel at α = 0.5000 on a smooth ramp: a tie with the metric's 0.5 threshold, not speckle. It is the same on the base commit, and Soften is unchanged code.

## What changed and why

**Expand (`refine.edge`) is now a flat greyscale dilation/erosion by a disc.** The old code rebuilt the boundary from the α = 0.5 set's signed distance and one global ramp width; when a mask held more than one width it fell back to "advecting" the alpha along the distance normal. That fallback samples the alpha a shift's distance away, so anything thinner than the shift gets sampled off itself. Colour and luminance ranges are made of exactly such features, which is why they flipped pixels 1 → 0 at every step. The reconstruction branch also replaced every smooth profile with a linear ramp the moment Edge left 0 (the 0.33 % erosion rise the old suite recorded as a known residual).

A flat dilation moves every level set by the radius. It's monotone by construction, keeps hard edges hard and plateaus at their density, and can only close holes (dilate) or remove islands (erode). The disc is an exact lattice disc up to 8 px (where an octagon is a poor disc) and a regular octagon beyond (four O(n) line passes at any radius, 0.96–1.04 × the radius by direction). Sub-pixel shifts blend adjacent integer radii. That only stays monotone if each structuring element contains the previous one. The first octagon rule broke that at radius 2 (two diagonals alone reach only a checkerboard), the unit test caught it, and the fix keeps one horizontal step; nesting is checked by brute force to radius 120.

**Follow (`refine.feather`) guides on colour.** The guided filter's guide was log-luminance only. It's now log-luminance plus 2 × OKLab a/b, with He et al.'s three-channel guided filter (per-pixel 3 × 3 solve). Same radius and ε. Raising the chroma weight to 4 or 8 bought nothing measurable (1.3k → 1.2k), so it stays at 2. The tooltip said Follow "does nothing where there is no edge". A guided filter on a flat region is a box blur of its radius, so the tooltip now says it softens there. I tried the obvious fix (blend back to the input where the guide has no variance) and rejected it: it leaves the original hard arc printed on top of the soft result, two edges instead of one.

**Speed.** Line passes use van Herk / Gil-Werman (three comparisons per pixel at any radius) and run lines concurrently. The colour filter's 13 window means and its solve run concurrently. Expand 0.34 s → 0.10 s. Follow 100 is 1.15 s before and after on 4 cores; on one core it's about 2× the old cost.

## Controls: kept, removed, merged

None removed. Each one measured as doing something the others can't:

| control | unique job | evidence |
|---|---|---|
| Follow | edge-aware: the only control that reads the photo | twigs/can separation (V2) |
| Expand | moves the boundary, keeps the profile | R2–R5 |
| Soften | widens the profile, keeps the boundary | coverage drift ≤ 0.053 % across 0–100 |
| Ramp from | drops faint selection | per-pixel monotone |
| Ramp to | makes partial selection solid | per-pixel monotone |
| Ramp shape | denser without clipping (γ > 1) | best from/to fit to γ = 2 misses by 0.081–0.106 mean on partial pixels; γ < 1 *is* nearly a Ramp-from move (0.005–0.037), so the half of the slider below 1 is the weak half |

If the panel ever needs a slot back, Ramp shape's γ < 1 half is the one to give up.

## Tests changed

- Removed `testASingleWidthMaskIsBitIdenticalToTheShippedReconstruction` and its verbatim copy of the old reconstruction. It pinned the behaviour this change exists to replace (profile → linear ramp). `testExpandMatchesAnExactDisc` holds the profile against the definition instead.
- Removed `testTheTransitionBandCannotSeeAHardEdge` and `testEverySingleEdgeMaskSitsUnderTheKneeWithMargin`. They tested `rampWidthSpread`/`rampCoherence`, statistics that only decided when to use the old reconstruction and no longer exist.
- `testTheSingleSoftRadialsResidualRiseIsBoundedAndRecorded` (allowed a 0.8 % rise) became `testTheSingleSoftRadialNeverRisesUnderErosion` (no rise). This is stricter, not looser.
- `testEdgeSweepsComponentCountFeatherMixAndRaster` lost its assertion that each fixture reads as "mixed width" (that statistic is gone); the sweep itself is unchanged.
- `testAdvectionMoves…` renamed `testExpandMoves…`, same assertion and tolerance.
- New `MaskRefineQualityTests` (8 tests) for R1, R2, R3, R4, R5, R7, R11.

Linux gates: `swift build --target LumenCore --target LumenRender` clean. `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` (CI's command, Swift 6.1.2): base 3044 tests pass; branch 3049 pass. `gen-fixtures.py --check` and `check-release-policy.rb` pass. `check-swift-surface.py` exits 1 here, and exits 1 on the base commit with the same findings (initializer and `set(_:forKey:)` call sites in LumenRender and LumenApp; only the totals differ, by this lane's new call sites, none flagged), so that failure predates this lane.

## Not fixed, and limits

- **N1/N2 (algebra).** Subtract `min(a, 1 − v)` → `a·(1 − v)`; Intersect Amount fades toward 1, not 0. Both need `MaskAlgebra.swift` + its golden (WS-42) and `KR.maskFoldSource` (M9) in the same commit as `MaskRaster.alpha`. Patches are in NEEDS.md.
- **Expand grows faint selection too (owner's call).** A flat dilation treats a 0.2 speck as selection and grows it like any other. On the 2545 sky colour range, Edge +25 takes coverage from 0.060 to 0.313 (the old code gave 0.071, because it thresholded at 0.5 and ignored faint values), filling the grass with grey octagons. Edge −25 punches octagonal holes, and on 8559 it removes the thin can handle entirely. Every one of these is the literal meaning of grow and shrink, but on a noisy range mask it reads as bubbles. Ramp from can't help, because it runs after Expand. If you want Expand to ignore faint selection, the change is one line: Expand a copy thresholded at a density floor and max it with the original. I didn't do it because it trades the monotone, profile-keeping definition for a heuristic.
- **Octagon tiles.** A flat dilation turns an isolated weak speck into a flat tile the shape of the disc. Past 8 px that's an octagon, visible at +25/+50 on the noisy colour range (left side of `expand_8559_colour.png`). It's what Expand means (Photoshop's Expand does the same with circles), and Follow or Soften first removes the specks. A 16-gon would hide the facets; I didn't build one.
- **Follow halves, not removes, a rough overshoot** (0.28 vs 0.55 at 2 px overshoot). A guided filter transfers structure; it doesn't snap. Snapping would be a matting solver, which is a different control.
- The S11 source here is the decoded frame, not the developed S11 input. The masks' relative behaviour is what's measured; absolute selections differ from the app's.
- `docs/quality/controls.{md,json}` still describes Expand as "via EDT" (NEEDS N3, outside this folder).

## A human must judge

Expand ±50 on a real colour-range mask in the loupe (are the octagon tiles acceptable?), and Follow 50–100 on a portrait against foliage (does the colour guide help hair, or only flat-colour objects like the can?).

## Process

Auditor and builder were the same agent (audit numbers are the "before" columns above). The verifier was a separate agent that saw only the spec and the diff. Round 1: FAIL. Expand was not monotone within 2 px of the frame, because the octagon's four chained passes clipped at the border (0.31 → 0.14 → 0.03 → 0.20 over Edge 17…19 on 983). It also flagged faint-speckle growth, the V3 wording and R9. Fix: pad by r with a replicated border before the passes, plus `testExpandIsMonotoneAtTheFrameBorder` from the verifier's reproduction. Faint-speckle growth went to the owner, V3 was reworded, and R9 is reported as failing as written.

## Evidence

The three to open first:

1. `evidence/expand_8559_colour.png`: Edge −50…+50 on the colour-range mask, before (rings, stripes) vs after.
2. `evidence/follow_8559_colour.png`: Follow 0/25/50/100, luminance guide vs colour guide; twigs in the handle.
3. `evidence/algebra_8559.png`: the subtract dead zone and the Amount-0 intersect, engine vs NEEDS proposal.

Also `expand_983_luma.png` (linear ∩ luminance range on 983) and `expand_983_hard_radial.png` (hard edge stays hard).
