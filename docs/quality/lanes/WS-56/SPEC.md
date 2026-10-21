# WS-56/57 acceptance spec: heal and clone spots, heal strokes

Written after the audit's first measurements. The ordering note is in REPORT.md:
the audit ran first, but this file landed after the first fixes rather than before them.

## How it is measured

Every case is a clean frame plus a synthesised defect, so the clean frame is the ground
truth (`Tests/LumenCoreTests/HealQualitySupport.swift`). Metrics are taken over the
area the heal writes (the reach: circle plus feather), in OKLab of the scene-linear
values normalised so the surround's mean luminance sits at 0.18.

| metric | definition |
|---|---|
| ΔE | OKLab ΔE ×100 between the mean of the healed core (ρ < 0.8) and the clean frame's |
| blotch | largest abs(low-pass(L_healed − L_truth)) in the disc, OKLab L ×100, box R/3 |
| seamStep | gradient discontinuity at the boundary: mean over 24 sectors of abs(mean L, ρ 0.88–1.0) − (mean L, ρ 1.0–1.12), minus the clean frame's own, ×100 |
| seamGrad | mean abs(∇L) over ρ 0.85–1.15, healed ÷ clean |
| texture | std of high-pass L in the core, healed ÷ clean (1 = same grain) |
| natural | the same metrics for the clean frame displaced 2.5 reach in 8 directions, median: how much clean neighbouring patches differ. On texture this is the bar |

Commands:

```
swift test --filter "HealQualitySpecTests|DustDetectionTests|StrokeSourceRepickTests"   # S1-S10, synthetic
LUMEN_HEAL_EVIDENCE=<dir> swift test --filter "testCorpusEvidence|testCorpusDustEvidence"  # C1-C5, corpus
python3 docs/quality/lanes/WS-56/tools/heal_sheet.py <dir> <out.png> [case...]   # sheets
```

## Measurable lines

| # | claim | threshold | measured by |
|---|---|---|---|
| S1 | No spots / no strokes is a byte identity; pixels beyond a spot's reach never move | exact | `SpotRetouchTests.testNoSpotsIsByteIdentity`, `testPixelsOutsideTheRadiusAreUntouched` |
| S2 | Dust on a noisy sky heals invisibly | ΔE < 0.1, blotch < 0.2, abs(seamStep) < 0.05, texture 0.85–1.15 | `HealQualitySpecTests.testS2` |
| S3 | The circle is fully replaced at every feather (feather lies outside) | < 0.01 stop of a speck that fills the circle, feather 0/50/100 | `testS3` |
| S4 | A fractional source offset borrows real pixels | cloned noise std ≥ 0.95 of the original | `testS4` |
| S5 | Heal re-lights multiplicatively: a source 2 stops darker keeps relative texture | texture > 0.8, ΔE < 1 | `testS5`; exponential ramp within 0.01 stop: `SpotRetouchTests.testHealReproducesAnExponentialRampAlmostExactly` |
| S6 | On texture the auto source lands within the picture's own variation | ΔE and blotch < natural; texture 0.8–1.25 | `testS6` |
| S7 | The search never pastes a second defect | the healed core is never darker than 0.9 of clean when every reachable source but one band holds a pit | `testS7` |
| S8 | A painted stroke over a wire on sky heals invisibly | ΔE < 0.1, blotch < 0.4, abs(seamStep) < 0.05, texture 0.85–1.15 | `testS8` |
| S9 | Strokes: ranked alternatives, `/` cycles, source drag moves only the offset | first = best; alternatives ≥ 1 radius apart; none borrows from the tube | `StrokeSourceRepickTests` |
| S10 | Dust auto-detect on a synthetic sky: all 10 specks (r 4–20, depth 8–40 %), circle 0.95–2.6× the speck, 0 on clean sky, 0 on texture and edges; the windowed whole-frame search finds each once | as stated | `DustDetectionTests` |
| S11 | GPU twin: the Core Image model of both spot kernels equals the reference to 1e-6; macOS `SpotRetouchGPUParityTests` and `StrokeHealGPUParityTests` pass at their existing 1e-3 | as stated | `SpotRetouchCoreImageModelTests`; macOS CI |
| C1 | Corpus sky dust (983 ×3, 1840 ×2), Heal | ΔE < 0.1, blotch < 0.2, abs(seamStep) < 0.05, texture 0.85–1.15 | evidence run |
| C2 | Corpus skin blemishes (skin_tones ×3) | ΔE < 0.05 | evidence run |
| C3 | Corpus texture (6929 foliage, ivy, wall; 1840 field, canopy), Heal | ΔE ≤ natural ΔE and blotch ≤ natural blotch on every case | evidence run |
| C4 | Corpus strokes (983, 1840 sky wire; skin; 6929 foliage, wall), Heal | sky/skin: ΔE < 0.1, texture 0.85–1.15; wall: blotch within 1.2× the base commit's | evidence run |
| C5 | Dust on corpus frames: planted sky specks found; false detections on clean frames | ≥ 90 % of planted SKY specks; ≤ 3 false on 983/1840/GX85 | evidence run (`dust.txt`) |

## Visual claims (a human judges from the named sheets)

- V1 `evidence/spots-sky.png`: at 3× zoom no healed sky dust is findable: no disc, no ring, no smoothed grain.
- V2 `evidence/spots-texture.png`: no healed foliage, ivy or wall spot pastes a second defect (pit, sky hole) or leaves a ring of the original speck.
- V3 `evidence/strokes.png`: a wire across the wall and its window heals without a copied window edge.

## Round 2 amendments (after the first verifier FAIL)

Added after verification, not before; the original lines above are unchanged and are
still reported against.

| # | claim | threshold | measured by |
|---|---|---|---|
| S12 | Dust auto-detect on a high-ISO sky (3.5 % pixel noise) still finds clear specks (30 %) and invents none | 3/3, 0 on the clean frame | `DustDetectionTests.testANoisySkyStillGivesUpItsDust` |
| C3b | Spots straddling an object edge (6933 leaf/branch/trunk, 1192 mound: the verifier's grid) | ΔE ≤ natural, reported per case; judged by eye on `evidence/spots-edges.png` | evidence run |
| C6 | Remove Dust on clean corpus frames (983, 1840, 6929, 6933, GX85 2545, R5 4694, R5 II 7881, D7200 832, Z6 3582, X-T10 1192) | ≤ 3 false detections in total | evidence run (`dust.txt`) |

C3b is split out of C3 because the verifier showed that on these cases a lower ΔE
against the truth can come with a WORSE picture (a pasted second branch, a pasted
striped object): mean colour does not see foreign structure, so these are judged by
eye, and the report says plainly that patch-copy heal cannot continue a trunk or an
edge (Lightroom sends that job to its generative Remove).
