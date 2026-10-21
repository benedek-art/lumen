# WS-39 Halation: report

Branch `quality/f1-halation` from `claude/inspiring-dirac-ulgpch` (`9068ded`).
Audit: `AUDIT.md`. Spec: `SPEC.md`. Measurements: `measure.py`. Needs from WS-38: `NEEDS.md`.

## For the owner

1. Halation used to be a red cast over every bright wall, lawn and sky (+4 to +7 codes at 100). It now adds nothing to flat areas and glows only beside things near or past the clip.
2. A clipped light now throws a real halo: orange next to the source, red in a long tail reaching 1.5–3% of the frame. Amount 100 + Size 2 + Redness 80 on Portra reads as a CineStill-style bloom.
3. Daylight frames change very little, which is correct: properly exposed whites don't halate on film either. Judge it on a night shot with street lights; the corpus has none.
4. Cine 250D's default halo is still too strong for a rem-jet stock, and there is no CineStill stock. Both are stock settings in WS-38 (`NEEDS.md`).
5. Lowering Film Lab Exposure now weakens the halo too (−2 EV gives a quarter). Pushing it raises it.

Best evidence: `evidence/01_clipped_light_before_after.png`, `evidence/02_no_cast_diff_maps_before_after.png`,
`evidence/03_1192_glass_100pct.png`.

## Verdict per spec line

Numbers from `measure.py --corpus` at `150c4df` and the builder's run (the verifier reproduced them).

| # | result | measured (before → after) |
|---|---|---|
| M1 identity at Amount 0 | PASS | early return on zero strength; byte-identical (`testAmountIsALinearGain`) |
| M2 flat fields no cast | PASS | max \|d\| at 0.18 / 0.9 / 1.0 / 4.0: 4 / 5 / 4 / 2 → 0 / 0 / 0 / 0 codes |
| M3 midtones don't feed | PASS | 0.18 and 0.25 disks: 4 and 8 → 0 and 0 codes |
| M4 clipped light glows | PASS | r2 default 0.42 → 1.46%, A100 0.50 → 2.29%, A100 S2 R80 1.04 → 3.25% of long edge; clipped/diffuse-white energy ≥ 3× (unit) |
| M5 colour | PASS | layer-space G/R falls with distance (unit); display G/R 0.090 at ring 1 → 0.049 at ring 40; R ≥ G ≥ B everywhere; Tri-X exactly neutral. Before: G/R 0.047 near vs 0.23 far (inverted), pure out-of-gamut red |
| M6 resolution | PASS | r2 2.13 / 2.29% at 800 / 2400 px |
| M7 Size | PASS (narrow) | r2 1.25 < 2.29 < 3.21%; S2/S0.5 = 2.57 (band 2.5–5) |
| M8 Redness | PASS | display G/R near source 0.121 > 0.042 > −0.035 |
| M9 Amount | PASS | stage exactly linear (unit, 1e-5); display steps 20.2 / 22.8 / 26.1 / 30.9% (band 15–35%, amended, see below) |
| M10 stock defaults | **BLOCKED on WS-38** | Velvia 0 < Ektar 0.034 < Portra 0.202 < Gold 0.238, Tri-X neutral: PASS. cine250D 0.230 is not ≤ Ektar: its default Amount is a WS-38 stock literal (`NEEDS.md`) |
| M11 corpus no cast | PASS | A100 mean dR in six flat regions: 2.5 / 7.0 / 5.9 / 4.9 / 5.5 / 4.1 → 0.0 / 0.0 / 0.4 / 0.07 / 0.05 / 0.01 codes |
| M12 GPU = CPU | PASS by review; CI: see below | verifier matched every term (gate, layer matrix, clamps, per-channel sigmas, normalized weights, gain matrix, kernel argument order) |

Visual lines: V1 PASS (`03_1192_glass_100pct.png`: the gold halo glass bleeds warm into the lead lines, wall and blue glass unchanged; subtle at the default). V2 PASS (`02_…`: snow, sky and chart whites unchanged; faint outlines only at chart-white edges). V3 PASS (`01_…`).

Verifier: round 1 FAIL on M9 (read before the band amendment), M10 (WS-38) and CI pending, plus one real finding (Film Lab Exposure ignored), fixed in `150c4df`. Round 2: see the end of this file.

## What changed and why

All in owned functions: `HalationProfile`, `FilmChain.halation/halationProfile`, `RR.applyHalation`, `RG.applyHalation`, `KR.halationEnergy` (kernel source only, no new registry row).

- **Only spread light is added**: `out = in + strength · max(F − H, 0)`. A stock's curve is measured on flat fields that already contain the base's reflection onto the same spot, so a flat field must be an identity. The old `strength · F` was a cast. The clamp keeps highlight cores from going cyan.
- **Gate**: one gate per pixel on its brightest record, zero two stops under the clip (was four, so mid grey fed the glow at a third of full weight).
- **Clipped-light reconstruction**: a sample at the clip is floored at 2 stops of energy (was 0.3 stop, so a lamp glowed no more than a white wall). HDR values above the floor stay linear.
- **Shape**: bounces at 1 : 3 : 8 × 65 µm at the gate (was 1 : 1.41 : 1.73), weights ½-decaying and normalized. Tight core, long tail. Still denominated at the gate, so the halo is the same fraction of the frame at any size.
- **Colour**: green/blue blur on 0.55× red's radii for a chromatic stock (1× for a neutral one), so the halo is orange near the source and redder outside. Strengths are applied in sRGB primaries and carried back to Rec.2020; in Rec.2020 primaries the halo was a laser red the display clamp rendered as pure (255, 0, 0)-type red.
- **Film Lab Exposure** scales the glow by 2^EV (light onto the film). Push/pull doesn't, since it is development.
- GPU twin built from existing kernels (`subtract`, `highlightEnergy(·,0,1)`, `addGlow`, `applyMatrix`).

## Tests changed and why

- `HalationControlTests`: removed `testNormalizingTheBouncesMovesNoPixel` (it pinned the old pixels byte for byte) and the flat-field form of `testTheRendererAppliesBounceWeightsThatSumToOne` (it required a flat field to glow). Added 8 tests for M1–M6, M9 and the exposure coupling. 16/16 pass.
- `KernelGoldenTests` (macOS): the halation width and gate goldens measured on flat fields or against a closed-form prediction of the old field. They now compare GPU against reference on a block source (spread within 10%, mass within 3%, the gate's closed end zero on both), same tolerances as before.
- Proof records `film.halation*.json` re-recorded. `ProofRegistry` floors on my two rows lowered (Amount 17 → 9, Size 11 → 4.5): on `wideStepEdge` the old 24.71 authority was mostly the cast over the bright side (mean separation 0.942 → 0.021). That frame's bright side is a diffuse white half a stop under the clip, so it is now correctly a small glow. **Integrator / WS-58: these are edits to existing rows of your registry, not appends.**

## Gates

- `swift build --target LumenCore --target LumenRender`: clean.
- Linux tests: 3049 executed, 0 failures, 6 skipped (all LumenCoreTests classes except `ControlProofTests`, which runs over 50 minutes in a debug build; CI's release Proof sweep runs it and is green on `c2149ee`). `HalationControlTests` re-run at `150c4df`: 16/16.
- Local workaround, not committed: Swift 6.0.3 rejects two trailing commas in `Sources/LumenApp/CompareView.swift` (pre-existing on base), which stops the Linux test bundle linking. Tests were run with those two commas removed temporarily.
- `scripts/check-swift-surface.py`: kernel and access passes clean; its one finding (`Font` in `LumenApp/LumenType.swift`) is outside this lane and pre-existing.

## Not fixed / for a human

- M10 cine250D default, and a CineStill stock: WS-38 (`NEEDS.md`).
- The CPU blurs with a three-box approximation above σ 8 px; the GPU uses Core Image's Gaussian. Mass and variance match; shape differs slightly in the far tail. Pre-existing, now reached more often because the third bounce is wider.
- The GPU stage takes `options.longEdge` from its caller where the CPU uses the image's own size. Same number in every path I could trace; not changed.
- In `--no-dither` renders the faint far tail on a black field shows 8-bit contour steps; the app's dither covers it.
- Coloured sources halate in their own colour (a green lamp throws a faint green halo). This is physically defensible but a human should judge it.
