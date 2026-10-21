# WS-50 mask refine chain + WS-43 component algebra: acceptance spec (lane M6)

Scope: `MaskRaster.refined/edgeShifted/guidePlane` and helpers, `MP.refineSection`,
`MaskRaster.combine/alpha/referenced`. GPU mask kernels are lane M9's; `MaskAlgebra.swift`
is WS-42's. Anything that needs either is written to `NEEDS.md`, not changed.

Measured on the CPU definition (`MaskRaster.combine`) through the lane tool
`tools/maskh` (rasterizes Mask JSON on a corpus `.lfi`, 2400 px long edge, the S11 source
approximated by the decoded frame). Corpus masks:

- **C**: colour range sampled on the red can, 8559 (Nikon Z fc)
- **RsC**: radial minus C, 8559
- **LiU**: linear ∩ luminance range (lo 0.50), 983 (Canon 5D IV)
- **hardR**: feather-0 radial on the lantern, 983

```
H=docs/quality/lanes/WS-50/tools
swift build -c release --package-path $H/maskh
python3 $H/cases.py OUT refine && for f in OUT/ref*.json; do $H/maskh/.build/release/maskh $f; done
python3 $H/refcheck.py OUT            # per-control metrics, refine_metrics.txt
python3 $H/cases.py OUT algebra && for f in OUT/alg*.json; do $H/maskh/.build/release/maskh $f; done
python3 $H/algcheck.py OUT
python3 $H/leak.py OUT                # Follow colour leak
swift test --filter 'MaskRefineQualityTests|MaskEdgeShift|MaskingTests|MaskGuidePlane'
```

## Refine chain (WS-50)

| # | claim | threshold | measured by |
|---|---|---|---|
| R1 | Every refine control at its default is an exact identity, and `MaskRefine()` keeps a gradient mask on the GPU path | bit-identical | `MaskRefineQualityTests.testDefaultsAreAnExactIdentity` |
| R2 | Expand is per-pixel monotone: raising Edge never lowers any pixel | worst wrong-way step ≤ 1e-6 over Edge −50…+50 on C, RsC, LiU, hardR and the unit mixed fixtures | `refcheck.py` `wrong` column; `testExpandIsMonotoneAtEveryPixel` |
| R3 | Expand never manufactures speckle | components < 16 px at any Edge ≠ 0 ≤ the count at Edge 0, on all four corpus masks | `refcheck.py` `speck` |
| R4 | Expand moves hard and soft boundaries by the same shift | both within ±1.5 px of the shift (Edge −40, 320²); Edge ±50 moves a hard radial's 0.5 crossing by 1 % long edge ± 6 % | `testAdvectionMovesTheHardAndSoftBoundariesByTheSameDistance` (renamed), `testFullTravelIsOnePercentOfTheLongEdge` |
| R5 | Expand keeps the edge profile: it shifts the existing ramp instead of rebuilding a new one | on a feather-100 radial, an erosion raises no pixel (> 1e-6); mean distance to an exact disc dilation ≤ 0.01 at Edge ±50 | `testErosionNeverRaisesAPixel`, `testExpandMatchesAnExactDisc` |
| R6 | Expand keeps partial density and hardness | the four `MaskEdgeShiftDensityTests` pass unchanged | those tests |
| R7 | Follow follows colour, not only brightness | off-colour leak at Follow 100 on C (mean alpha gained by pixels with OKLab ΔE > 0.15 from the sample that were < 0.05 before) ≤ 50 % of the luminance-guide leak | `leak.py` |
| R8 | Follow does something visible from low values and is identity at 0 | Follow 10: max change ≥ 0.25 on C and hardR | `refcheck.py` `max` |
| R9 | Soften blurs without moving the mask | coverage drift ≤ 0.5 % over 0…100; stair metric non-increasing from 5 up; speckle 0 from 25 up | `refcheck.py` |
| R10 | Ramp from / to / shape are per-pixel monotone, exact identity at defaults, and Ramp shape is not redundant | wrong-way 0; best Ramp from/to fit to γ = 2 leaves mean error > 0.05 on partial pixels | `refcheck.py`; `REPORT.md` table |
| R11 | Alpha stays finite and inside [0, 1] at every setting of every control | 0 violations | `testWholeChainStaysInRange` |
| R12 | Expand is not slower than before at 2400 × 1600 | wall time ≤ the base commit's | `maskh` timings |

## Component algebra and references (WS-43)

| # | claim | threshold | measured by |
|---|---|---|---|
| A1 | CPU fold = `MaskAlgebra` semantics (add = max, subtract = min(a, 1 − v), intersect = a·v) | max |Δ| = 0 | `algcheck.py` |
| A2 | Subtract removes partial selection where both overlap (Lightroom: a 50 % subtract over a 40 % feather reduces it) | no overlap pixel with 0.05 < a, v left untouched | `algcheck.py` "removed nothing" fraction |
| A3 | `R − C` equals `R ∩ inverted C` (two spellings of one selection) | max |Δ| < 1e-6 | `algcheck.py` |
| A4 | Component Amount 0 is "this component does nothing" for every op | identity for add, subtract, intersect | `algcheck.py`, unit test |
| A5 | A reference is the referenced mask's finished alpha; nested inverts compose exactly (ref, inverted ref, inverted mask of an inverted ref, ref to an inverted mask) | max |Δ| = 0 | `algcheck.py` |
| A6 | Whole-mask invert runs before refine, so Expand grows what is now selected | existing `testWholeMaskInvertRunsBeforeTheRefinementChain` | test |

## Visual claims

- V1 `evidence/expand_8559_colour.png`: Edge −50…+50 on the colour-range mask shows no rings, bubbles or torn stripes; the selection grows and shrinks as one shape.
- V2 `evidence/follow_8559_colour.png`: at Follow 100 the twigs seen through the can's handle stay unselected.
- V3 `evidence/algebra_8559.png`: radial minus colour range at component amount 50 shows the can removed by half, graded with the colour match, not a flat plateau.
