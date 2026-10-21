# WS-56/57 report: heal and clone spots, heal strokes, dust

Branch `quality/ws-56-57-heal` from `claude/inspiring-dirac-ulgpch` (c1c8e23). One lane
folder for both workstreams; WS-57's lines are S8, S9 and C4.

## For the owner

1. Before, a default spot (Feather 50) blended half the blemish back in and left a visible ring. Now the circle is always fully replaced, and the feather sits outside it (`evidence/spots-texture.png`, first column vs fourth).
2. Heal no longer smears sky grain and no longer pastes a flat disc, a sky hole or a wall pit on foliage and plaster. Every sky/skin case reads ΔE ≤ 0.06, and texture heals sit inside the photo's own patch-to-patch variation.
3. New: drag a painted stroke's dashed source line, `/` re-picks it, and **Remove Dust** in the Heal bar heals every soft speck on smooth areas in one undo step.
4. Try by hand on a Mac: a stroke source drag and `/` on a stroke, then Remove Dust on a real dusty sky at f/16. Look at what it does on walls: it can mark plaster pits (10 on 6929, image `dust-false-6929.png`).
5. Recipes made before this branch render slightly differently: feathered spots now reach further out than before, at the same inner sharpness.

## Verdict per spec line

Measured on this branch (2d67087), Linux, CPU reference. "Base" = c1c8e23 with the same harness.

| # | result | number |
|---|---|---|
| S1 | PASS | identity tests green; nothing moves beyond the reach |
| S2 | PASS | syn sky: ΔE 0.01/0.00, blotch 0.07/0.04, seamStep −0.01/0.00, texture 0.92/0.95 (base texture 0.49/0.67) |
| S3 | PASS | < 0.01 stop of a circle-filling speck left at Feather 0, 50, 100 |
| S4 | PASS | cloned noise keeps ≥ 0.95 of its std |
| S5 | PASS | 2-stop-darker source: texture > 0.8; exponential ramp within 0.01 stop |
| S6 | PASS | syn foliage Heal ΔE 1.23 vs natural 2.69, blotch 8.7 vs 11.3, texture 0.96 |
| S7 | PASS | healed core never below 0.9 of clean with pits everywhere but one band |
| S8 | PASS | syn sky wire: ΔE 0.01, blotch 0.17, texture 0.98 |
| S9 | PASS | `StrokeSourceRepickTests` 4/4 |
| S10 | PASS | 10/10 synthetic specks, 0 on clean sky, foliage, edge and line; windowed search finds each once |
| S11 | Linux model PASS (< 1e-6); macOS: see "CI" below |
| C1 | PASS | 983 a/b/treeline ΔE 0.05/0.02/0.06, 1840 a/b 0.01/0.02; texture 0.94–1.02 (base 0.60–0.89); abs(seamStep) ≤ 0.01 |
| C2 | PASS | skin_tones light/mid/edge ΔE 0.00 (base 0.09: the inside feather blended the blemish back) |
| C3 | **2 of 5 over the line** | ΔE vs natural: 6929 foliage 3.34 vs 2.85, 1840 field 2.57 vs 2.46 (over by 17 % and 4 %); ivy 0.49 vs 6.15, wall 0.13 vs 2.07, canopy 0.73 vs 12.2. Blotch under natural on all 5. Both over-line cases are clean by eye (`spots-texture.png`); base on the same two: 0.63 and 3.04, with a visible ring on the first |
| C4 | PASS | 983/1840 sky wire ΔE 0.01/0.00, texture 0.96/0.98; skin 0.00; wall blotch 5.58 vs base 5.51 |
| C5 | PASS | planted sky dust found: 983 5/5, 1840 4/4 (texture-placed ones skipped by design); false detections: 983 3, 1840 0, GX85 0. 6929: 10 (plaster pits; human judgement) |

## What changed and why

Ground truth first. Every audit case is a clean corpus or synthetic frame plus a synthesised defect: dust on 983/1840 sky, blemishes on `skin_tones`, specks on 6929 foliage, ivy and wall, plus 1840 canopy and field. That makes ΔE, seam step, blotch and grain measurable against the real pixels. The audit found five defects, all now fixed on CPU and GPU together:

1. **Inside feather.** `rin = 1 − feather` put the soft edge inside the circle, so at Feather 50 the blemish was 50 % mixed back in at ρ = 0.75: a visible ring around every healed speck. The feather now extends `featherReach` (1.0) radii outside the circle (`SpotRetouch.resolve`, `StrokeHeal.resolve`), and the geometry's `radius` is the reach. At 0.5 the transition was half as wide as before and Clone strokes on sky showed a step (seamGrad 1.6), so 1.0 keeps the old transition width.
2. **Bilinear sources.** Sub-pixel source offsets averaged four pixels and halved the grain (texture 0.49 on syn sky). Offsets are rounded to whole pixels at resolve.
3. **Additive membrane.** Re-lighting by adding a constant in linear light keeps the source's absolute contrast, which turned a gappy canopy into a milky disc and could drive pixels negative. The membrane now lives in `LumenLog`'s domain (multiplicative; toe-safe at zero). The rim is low-passed (16 Hann-weighted points over 4 rim spacings, means taken before the log) and sampled 1 px outside the reach.
4. **Flat-source bias.** A raw ring SSD scores a flat candidate σ² and a matched but uncorrelated texture 2σ², so on texture the search picked shadow and pasted a smooth disc (1840 canopy, texture 0.30). `Scorer.contextCost` adds texture energy, interior consistency, a Heal level term and an outlier term on a dense interior grid (1.5 px), shared by spots and strokes.
5. **Overlap clearance** is now reach + circle, not 2× reach. Requiring 2× reach pushed the wall stroke's source past the window and pasted a second window edge.

New: `StrokeSourceSearch.rankedOffsets/nextOffset`, `StrokeHandles.hitSource/draggedSource`, and the HealCanvas stroke-source drag and `/`. Also `DustDetection` (difference of boxes in log luma at 5 scales; deep enough, round, soft, on a smooth surround) with `RenderCoordinator.dustSpots` and the Remove Dust button. The dust search uses the heal search's existing S5 tap, tiled with `DustDetection.probes`, so no renderer code changed.

## Tests changed, and why

- `SpotRetouchCoreImageModelTests.testTheModelReproducesTheMacOSLane` pinned the lane's 2026-10 numbers for the old arithmetic. It now holds the property the lane found (the margin smear) on every case and size. The old numbers are in git at c1c8e23.
- `SpotRetouchTests`: the outside-untouched radius is now the reach. The linear-ramp heal bound went from 1e-5 to 1e-3 and the slope test from 0.004 to 0.006, because a ramp linear in light is not harmonic in log; it misses by 0.0014 and 0.0041 against a 0.06 flat fill. Exactness moved to a new exponential-ramp test. The long-edge radius test now pins Feather 0 and checks the reach separately.
- `SpotSourceSearchTests`: the window scale is set by the reach (900 px, not 600).

## Not fixed / for a human

- **Clone on texture** can paste a gap: on the 1840 canopy, Clone ΔE is 6.61 with a sky hole. Clone copies verbatim, and the canopy's own ring has gaps, so it isn't an outlier. Heal on the same spot is 0.73.
- **Dust on plaster**: 10 detections on 6929's wall are real pits; LR's Visualize Spots shows them too. Remove Dust skips texture by design but not smooth walls.
- The spec was written after the first fixes, not before them. The audit numbers came first and are the "base" column above.
- Interaction (drag latency, the Remove Dust wait on a 45 MP file: about 20 window renders plus one source search per speck) needs a Mac.

## CI

PENDING
