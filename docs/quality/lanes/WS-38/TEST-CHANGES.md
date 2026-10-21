# WS-38 test changes

## Regenerated goldens (behaviour deliberately changed)

- **`Tests/LumenCoreTests/Fixtures/enginemath.json` → `"film"` rows**, which `EngineMathFixtureTests.testFilmChainMatchesTheReference` replays.
  - These rows are the grey ramp through every stock, as sampled by the Python mirror in `scripts/gen-fixtures.py`. The audit (§2) lists them as "encodes current numbers, not desirable behaviour".
  - The mirror was rewritten to implement the new chain faithfully, and `python3 scripts/gen-fixtures.py` regenerated the file. The tolerance is unchanged (1e-7), and no other section of `enginemath.json` or any other fixture changed.
  - The new chain: toe → straight → shoulder negative, coupling, per-channel density-weighted tints, a print rolled into paper white and paper black, the push crush, and the neutral black floor, with printer lights solved per channel at every film exposure.
- **The mirror's own Linux-side checks (`gen_film_checks`)** were updated to the new behaviour, not loosened:
  - Mid-grey is now asserted at every film exposure × push for negatives, because the lab prints them back to grey. It used to be asserted only at exposure 0.
  - The monotone sweep covers −12…+8 EV at every exposure and push.
  - Two new checks: white is reached at +9 EV (≥ 0.98) and black is not lifted at −12 EV (< 0.002).
  - The push-direction check now respects each stock's push range. Velvia 50 is −½…+1, and a value past the range must render the same as the end of the range.
  - The crossover-bound check is now an absolute 0.15 density. The old 5 %-of-span rule assumed the tints added to a sigmoid's whole density span. The tints are now weighted by density, so they are monotone by construction (`FilmCrossover` doc).

## Proof registry (`Tests/LumenCoreTests/Proof/ProofRegistry.swift`) and its committed records

`ControlProofTests` holds every control to an authority floor and to exact committed records (`Proof/records/*.json`). The film entries were calibrated on the old picture, so they encode the defects this lane removed. They were re-measured on the new chain, and the floors were restated at the same fraction (0.7 of the measurement) the old ones were set at. The reasons are spelled out in the registry comments.

- **`film.<stock>.strength`:** the shared floor of 59 becomes one floor per stock, at 0.7 × its own measurement.
  - Measured peak separation from Neutral on `tonalColourWedge`: Portra 12.1, Gold 16.5, Ektar 25.9, Velvia 57.4, Cine 19.6, Tri-X 139.6. The old values were 85…195.
  - The old values were mostly lifted blacks, grey whites, ×1.5–2 muted-colour chroma and the hard sRGB clip of the wedge's gamut-edge hues (AUDIT §0, §4, §5).
  - The spec pins Portra and Cine near Neutral (S10, S12, S16), and the gamut lines (S20, S21) keep the wedge's edge hues inside the boundary.
- **`film.exposure`:** floor 130 → 53 (0.7 × 75.46), plus a declared reversal of 22.805.
  - The old 186 was Film Exposure acting as a brightness slider: +3 printed 2 EV brighter (AUDIT §7). The spec (S27) and the control's own doc comment say it must not do that.
  - A lab-normalised exposure moves a boundary. Underexposure lifts the shadows into fog (S29) and overexposure presses them down (S28), so some travel is handed back by construction.
- **`film.grain.size`:** declared reversal 21.183 → 22.262. Grain is unchanged; the film picture under the plate changed. This is the only number touched in a WS-40 entry.
- **The 13 `film.*` records** were re-recorded with the new chain (written by `ProofRecordStore.write`). No other record changed.

## New tests

`Tests/LumenCoreTests/FilmStockLookTests.swift` (13 tests) covers the SPEC lines that can be stated on `FilmChain` directly:

- grey anchor at every exposure and push, with negatives lab-normalised (S1, S27)
- slide exposure is scene exposure (S30)
- contrast order (S2, S3)
- white point (S4, S36)
- dense, neutral blacks (S7, S8)
- over/under exposure (S28, S29)
- push contrast and toe (S31, S32)
- the Velvia push clamp (S34)
- Tri-X panchromatic and exactly neutral (S22, S23)
- finite, in-gamut output, with over-range light bleaching (S20, S21, S36)
- Portra skin and sky hue against neutral (S16, S18)
- saturation order (S13)
- coloured ramps monotone (S35)

## Existing tests

None was skipped or disabled. The only thresholds that moved are the proof-registry floors above. They were re-derived on the new picture at the fraction they were first set at, and the reason for each is in the registry. These pass unchanged:

- `EngineIntegrationTests`: every-stock mid-grey anchor, the no-inversion sweep, the convex Strength blend, the solve memo
- `FilmLabHDRMidGreyTests`, `FilmLabDisplayTransformTests` and `RobustnessTests`

## Round 2

- **`enginemath.json` `"film"` rows were regenerated.** The Python mirror (`scripts/gen-fixtures.py`) follows the round-2 tables (`FILM_STOCKS`), the pull rates (`pullGammaPerStop`, `printToePerPullStop`) and `FILM_NEUTRAL_BLACK_SPAN` = 20. The tolerance is unchanged, and all Linux-side verifications pass.
- **`FilmStockLookTests`: no test was changed.**
  - Two tests failed on an intermediate round-2 build: the neutral paper black (spread 1.2e-4 > 1e-4) and Portra's deep-skin hue (4.6° > 4°). Both were fixed in the code, not the tests: `neutralBlackSpan` 15 → 20, and Portra's red-skin lobe 2.0 → 0.5.
- **The 13 `film.*` proof records were re-recorded** with the round-2 chain. No floor or declared reversal moved, because every measurement is above its floor:
  - strength authority: Portra 16.8 (floor 8), Gold 18.5 (11), Ektar 23.9 (18), Velvia 57.0 (40), Cine 26.2 (13), Tri-X 139.6 (97)
  - film.exposure: authority 78.2 (53), gave back 17.5, declared reversal 22.805
  - film.pushPull: authority 52.8 (22)
  - film.grain.size: gave back 21.6, declared reversal 22.262
  - halation and grain entries: unchanged in substance
