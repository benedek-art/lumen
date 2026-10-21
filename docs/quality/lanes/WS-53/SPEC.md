# M8 acceptance spec: WS-53 local presence & sharpness, WS-54 local curve, WS-55 local noise/moiré/defringe/grain

One lane folder for the three workstreams. Written from the audit (`AUDIT.md`) before any
code changed. Tools: `tools/run.sh <id> <out.png> [lumen-render args]` renders one frame
with the sidecar's as-shot WB and ISO, `tools/diff.py a.png b.png` prints max / mean /
%>2 codes. `F` = `tools/full.json` (radial, radii 5, feather 0: alpha 1 everywhere),
`R` = `tools/radial.json` (radii 0.25/0.30, feather 50), `N` = `tools/none.json`.
Photo set P = 6929, 6933 (A7 IV), 2545 (GX85), 1569 (GX80), 2348 (G9, ISO 3200),
4694 (R5), 983 (5D4) + synthetic zone_plate, hard_edge, colorchecker, skin_tones.
All renders `--no-dither`, `--long-edge 1024` unless stated. "Codes" = 8-bit sRGB.

## Part 1. Local = global × alpha

1. **Full-frame Texture/Clarity/Dehaze equal global.** For X ∈ {texture, clarity, dehaze},
   v ∈ {−100, −50, 50, 100}, every image in P: `F` + `masks.0.adjust.X=v` vs `N` +
   `develop.detail.X=v` → max diff 0 codes. (Holds at default global colour; see 12.)
2. **Full-frame Sharpness equals global Sharpen at the user's sharpen settings.** For
   v ∈ {50, 100}, with global `develop.detail.sharpen.{radius=2, detail=60, masking=60,
   haloSuppression=40}` and global amount 0: `F` + `masks.0.adjust.sharpness=v` vs `N` +
   same settings + `sharpen.amount=v` → max ≤ 1 code on 2545, 6929, zone_plate (baseline:
   max 50, mean 4.0 on 2545). Unit test: `LocalPresenceTests.testLocalSharpnessUsesTheGlobalSharpenSettings`.
3. **Negative Sharpness has no dead zone.** On 2545 at `--long-edge 0`, `F` +
   sharpness=s vs `N`, mean diff m(s): m(−10) ≥ 0.15·m(−100) and m(−25) ≥ 0.35·m(−100),
   and m is strictly increasing over −10, −25, −50, −75, −100 (baseline m(−10)=0.003,
   m(−100)=12.4). Unit test on CPU: `testNegativeSharpnessRespondsFromTheFirstStep`.
4. **No seams or halos at the edge.** `R` with each of texture/clarity/dehaze/sharpness at
   ±100 and a local curve, `--long-edge 0`, on 6 photos of P: outside alpha 0 → 0 codes
   changed; in the feather 0.00 % of pixels outside [min(none, full), max(none, full)] ± 1
   code (`tools/radcheck.py`). Visual: `evidence/edge_*.png` at 100 % shows no step.
5. **Local curve equals the global curve** for 5 curves on 7 images: max ≤ 3 codes at
   lut-size 33, ≤ 2 at 65 (table error only).
6. **Identity.** A mask with every adjust field at its default (new fields included) and
   Amount 0 renders byte-identical PNGs to no mask. Unit test:
   `testDefaultLocalAdjustIsAnExactIdentity`.

## Part 2. Noise, Colour noise, Moiré, Defringe, Grain

7. **Local Noise renders, and is the global engine.** With global NR off and a neutral
   recipe, a full-frame alpha and `noise = v` (v ∈ {30, 70, 100}) through
   `ReferenceRenderer.applyMasks` equals `ClassicalDenoise(luma: v, chroma: 0, …)` with
   the plan's profile applied to the same buffer: max |Δ| ≤ 1e-5 linear. Same for
   `noiseChroma` vs `chroma: v`. Unit tests in `LocalNoiseTests`.
8. **Local Noise follows exposure.** With global Exposure +2 EV, the profile handed to
   the local engine is (g·a, g²·b), g = 4: unit test compares to an engine built with that
   profile, ≤ 1e-5.
9. **Local Noise reduces noise only inside the mask.** On 2348 (ISO 3200) at
   `--long-edge 0`, `R` + noise=100: high-pass σ in a flat patch inside the mask
   drops ≥ 30 % vs no mask; outside alpha 0, 0 codes changed. Monotonic in v
   (0, 25, 50, 75, 100): σ non-increasing.
10. **Preview honesty.** Local Noise obeys `ClassicalDenoise.scaled(noiseScale:)`: at
    noiseScale ≤ 0.5 it is the identity on both paths, exactly like the global stage.
    Unit test `testLocalNoiseFollowsTheGlobalPreviewRule`.
11. **Moiré, Defringe, Grain stay unrendered and unoffered**, still round-trip, and the
    panel offers no row for them. `MaskDeadFieldTests` keeps those three rows; `noise` and
    `noiseChroma` leave it. Reasons in REPORT.md.

## Documented, not fixed in this lane

12. Full-frame local Dehaze/Clarity diverge from global once global colour/grade is
    edited (local presence runs after S9/S10). Measured and recorded; the fix moves a
    stage and goes to NEEDS.md (WS-01).
13. Clarity +100 speckle on grass (global engine, WS-14) and the Texture/Amount-200
    limit inconsistency (`DetailEngine.scaledPresenceAmount`, WS-14) go to NEEDS.md.

## Gates

14. CPU and GPU change in the same commit; `RenderGraph` local NR calls the same
    `ClassicalDenoise.gpuPlan` as S3. `swift build --target LumenCore --target LumenRender`
    clean; LumenCoreTests: no new failures against the base commit.

## Visual claims (human judges)

- V1 `evidence/noise_g9_*.png`: ISO 3200 G9 sky/shadow at 100 %, none vs local Noise 70
  in a radial. The masked area is cleaner with no plastic edge at the feather.
- V2 `evidence/sharp_neg_*.png`: local Sharpness −10/−25/−50/−100 at 100 %, each a
  visible step softer than the last.
- V3 `evidence/edge_*.png`: radial feather on a real photo with Clarity/Dehaze ±100, no rim.
