# WS-56/57 report: heal and clone spots, heal strokes, dust

Branch `quality/ws-56-57-heal` from `claude/inspiring-dirac-ulgpch` (c1c8e23). One lane
folder for both workstreams; WS-57's lines are S8, S9 and C4. Round 1 (2d67087) failed
verification; this is round 2.

## For the owner

1. A default spot used to blend half the blemish back in and leave a ring. The circle is now always fully replaced, and the feather sits outside it (`spots-texture.png`, heal_before vs heal_after).
2. Sky dust and skin blemishes heal invisibly (ΔE ≤ 0.07, grain kept). Spots that straddle a branch, a trunk or an object's edge still get a plausible-but-wrong patch (`spots-edges.png`). A patch copier can't continue a trunk; Lightroom uses generative Remove for that.
3. New: drag a painted stroke's dashed source line, press `/` on a stroke to re-pick it, and use **Remove Dust** in the Heal bar. Remove Dust found 8 of 9 planted sky specks and made 2 false detections across 10 clean photos.
4. Try on a Mac: a stroke source drag, `/` on a stroke, and Remove Dust on a real dusty f/16 sky.
5. Spots in recipes made before this branch reach further out when feathered (the feather moved outside the circle).

## Verdict per spec line

Measured on this branch, Linux CPU reference. "Base" is c1c8e23 run through the same harness.

| # | result | number |
|---|---|---|
| S1 | PASS | identity tests green; nothing moves beyond the reach |
| S2 | PASS | syn sky ΔE 0.01/0.02, blotch 0.07/0.06, seamStep −0.01/0.00, texture 0.92/0.94 (base texture 0.49/0.67) |
| S3 | PASS | < 0.01 stop of a circle-filling speck left at Feather 0/50/100 (Heal) |
| S4 | PASS | cloned noise keeps ≥ 0.95 of its std (worst offset only just: 0.950) |
| S5 | PASS | 2-stop-darker source: texture > 0.8; exponential ramp within 0.01 stop |
| S6 | PASS | syn foliage Heal ΔE 1.31 vs natural 2.69, blotch 5.8 vs 11.3, texture 1.03 |
| S7 | PASS | healed core never below 0.9 of clean with pits everywhere but one band |
| S8 | PASS | syn sky wire ΔE 0.01, blotch 0.17, texture 0.98 |
| S9 | PASS | `StrokeSourceRepickTests` 4/4 |
| S10 | PASS | 10/10 synthetic specks; 0 on clean sky, foliage, edges, lines |
| S11 | Linux model PASS; macOS parity green on 2d67087 (same kernels as this round) |
| S12 | PASS | noisy-sky dust 3/3, 0 false |
| C1 | PASS | 983 a/b/treeline ΔE 0.05/0.02/0.07, 1840 a/b 0.01/0.02; texture 0.94–1.02 (base 0.60–0.89) |
| C2 | PASS (trivial) | skin_tones ΔE 0.00; the swatches are flat, so this only proves the blemish is gone (base left 0.09) |
| C3 | **FAIL, 2 of 5** | 6929 foliage 3.34 vs natural 2.85; 1840 field 2.57 vs 2.46. Under natural: ivy 0.67 vs 6.15, wall 0.13 vs 2.07, canopy 0.73 vs 12.2. Blotch under natural on all 5 |
| C3b | judged by eye, mixed | 6933 leaf 5.94 vs 4.53 (over), branch 4.44 vs 5.20, trunk 3.58 vs 5.46, 1192 mound 5.15 vs 6.75; see below |
| C4 | PASS | sky wires ΔE 0.01/0.00, texture 0.96/0.98; skin 0.00; wall blotch 5.05 vs base 5.51 |
| C5 | **FAIL by one speck** | planted sky specks 8/9 (983 4/5, 1840 4/4). The miss sits 30 px from the mountain's soft edge. False detections on 983/1840/GX85: 0 |
| C6 | PASS | 2 false detections on 10 clean frames (6933 1, R5 II 7881 1); round 1 had 107 |

## What I tried for C3 and C3b, and why it stays

Round 2 swept seven variants of the source scorer: without the energy, consistency, outlier or level terms; level split into luma and chroma; the context ring measured from the circle instead of the reach; and a hybrid ring. Results are in the scratch `sweep*.txt` files.

The circle-relative ring put every texture case under natural variation on ΔE. At 2× zoom, though, it pasted a second branch into 6933 and a striped object onto the 1192 mound. A lower ΔE against the truth came with a worse picture. The hybrid ring continued the 6933 trunk correctly, but pasted a sky hole into the 1840 canopy.

No variant was better everywhere by eye, so round 1's ring stays. The one change kept is the full-disc outlier grid, which fixes a real defect: a wall pit was pasted when the grid stopped at 0.95. This was the ceiling of patch-copy heal on spots that straddle structure. A structure-aware or generative fill is the fix, and it is out of this lane's scope.

## What changed and why

Every audit case is a clean frame plus a synthesised defect, so ΔE, seam, blotch and grain are measured against the real pixels. Defects found and fixed, CPU and GPU together:

1. **Inside feather.** At Feather 50 the blemish was 50 % mixed back in at ρ 0.75, leaving a visible ring. The feather now extends `featherReach` (1.0) radii outside the circle or tube.
2. **Bilinear sources.** A sub-pixel offset averaged four pixels and halved the grain (texture 0.49). Offsets are rounded to whole pixels.
3. **Additive membrane.** It kept the source's absolute contrast, which turned a gappy canopy milky. Heal now re-lights multiplicatively in `LumenLog`'s domain. The rim is low-passed (16 Hann points over 4 spacings) and sampled 1 px outside the reach.
4. **Flat-source bias.** A raw ring SSD prefers a flat patch on texture (1840 canopy, texture 0.30). `Scorer.contextCost` adds texture energy, interior consistency, a Heal level term and an outlier term on a grid covering the full disc. Strokes share it.
5. **Clearance** is reach + circle: 2× reach pushed the wall stroke's source past the window.

New features:

- Strokes: `StrokeSourceSearch.rankedOffsets/nextOffset` and `StrokeHandles.hitSource/draggedSource`, plus the HealCanvas drag and `/`. During the drag the set lives in the stroke cache under its future content hash, and the blob is written once at the end.
- Dust: `DustDetection`, a difference of boxes in log luma at 5 scales. A hit must be deep enough, round, soft, on a smooth local surround, and on a surround smooth over a wide window measured on a band-pass plane. The band-pass keeps a gradient and pixel noise from counting as roughness, so a speckled bowl, wallpaper or plaster isn't searched.
- Remove Dust (HealCanvas): one window per coordinator call (`RenderCoordinator.dustWindow`), so the actor is free between windows. Detection runs off the actors and the source search runs per speck. Pressing the button again stops it.

## Tests changed, and why

- `SpotRetouchCoreImageModelTests.testTheModelReproducesTheMacOSLane` pinned the 2026-10 lane numbers for the old arithmetic. It now holds the property the lane found (the margin smear) on every case and size. The old numbers are in git at c1c8e23.
- `SpotRetouchTests`:
  - The outside-untouched radius is now the reach.
  - The linear-ramp bound went from 1e-5 to 1e-3, and the slope bound from 0.004 to 0.006: a ramp linear in light isn't harmonic in log. They miss by 0.0014 and 0.0041 against a 0.06 flat fill, and exactness moved to a new exponential-ramp test.
  - The long-edge radius test now pins Feather 0.
- `SpotSourceSearchTests`: the window scale is set by the reach (900 px, not 600).
- `Tests/LumenAppTests/LayoutMetricSupport.swift`: the four Heal bar slider citations now point at their moved lines. This was the round-1 CI failure. It is a mechanical re-point, following `d0f518f`'s precedent, in a file outside the lane's rows.

## Ownership

Edited outside the WS-56/57 rows, all additive, for the integrator to sign off:

- `StrokeHandles.swift` (stroke handles) and `RenderCoordinator.swift` (`healStrokeOffsetCandidates`, `dustWindow`, beside the existing heal taps).
- The new `DustDetection.swift`.
- The Remove Dust button, inside the HealCanvas panel body, which WS-56 owns.
- `LayoutMetricSupport.swift` (citations only).

## Not fixed / for a human

- **Spots straddling an edge** (C3b, `spots-edges.png`) get a wrong-but-plausible patch, the same class of failure for Heal and Clone.
- **Clone on texture** can paste a gap where Heal doesn't. The 1840 canopy and syn foliage show it: Clone ΔE 4.50 vs Heal 1.31.
- **A source dragged into deep shadow** comes back with its grain amplified (the verifier measured about 10× relative std from a 1e-4 source). That is what multiplicative re-light does. Auto-sourcing never picks such a source; a hand drag can.
- **Remove Dust skips dust beside a strong edge**: the mountain-edge speck in C5.
- **SPEC.md was written after the first fixes**, and round 2 added amendments (S12, C3b, C6), marked as such.
- **Full LumenCoreTests on Linux** didn't finish: one "C" class ran for 4 hours on Swift 6.0.3 debug before I killed it. macOS `ci.yml` test-fast ran the whole suite on 2d67087: 3783 of 3784, with the one failure the layout citation fixed here. Spot/stroke/heal/dust classes: 117 tests, 0 failures. The surface checker is clean.

## CI

2d67087 (round 1): GPU parity, UI layout, UI snapshots and Proof sweep green; `ci.yml` red on `LayoutMetricSelfTests`, fixed in 098a57c. Round 2: see the final commit's runs.
