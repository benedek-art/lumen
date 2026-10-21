# WS-38 report: film stocks and the film chain

**STATUS (paused by director, 2026-10-21): NOT DONE. Build round 2 committed; independent verifier verdict FAIL. Do not merge.** 36 of 39 spec lines pass on fresh measurement; all 3057 LumenCoreTests pass on Linux (ControlProofTests not run end to end). Verifier found a real regression at Film Exposure −2 with Push +1.5…+2 (green-teal flooded shadows on every colour negative) and worse 33³ preview-table accuracy for Ektar/Velvia. Round 3 (builder fix, re-verify) has not started.

## For the owner

- The stocks no longer look like "neutral plus a vibrance slider": real whites, dense neutral blacks, no orange or ashen skin, skies no longer clip.
- Each stock now has a character: Velvia vivid and contrasty, Ektar punchy, Gold golden, Cine soft and teal, Tri-X a panchromatic mono. Portra is warm and gentle, but only about 1.5–1.9 ΔE from neutral, so judge it by eye.
- Film Exposure now behaves like a lab print (brightness held, character changes) instead of a brightness slider. Push/pull add contrast and lose shadow detail like the darkroom.
- Not ready: underexposure combined with a heavy push turns the shadows green, and Ektar/Velvia previews differ from export until the finish table is finer (NEEDS.md).
- Evidence: `evidence/before_4694.png` → `evidence/after_4694.png`, `evidence/after_983.png`, `evidence/after_skin_tones.png`.

## Verdict per spec line (verifier's fresh measurement, `python3 docs/quality/lanes/WS-38/measure.py`)

S1–S36: PASS (S6, S12–S15, S24, S26, S33 under lead amendments recorded in SPEC.md, with the originals kept). S37: FAIL (Velvia max 4.9 ΔE at 65³; at the shipping 33³ Ektar 3.51/7.65 and Velvia 3.94/8.86 p99/max, against baseline Velvia 2.41 p99). S38: FAIL (Portra 1.54 and Cine 1.8 vs neutral on the chart, need 2.5). S39: FAIL (Cine 1.57, Portra 1.9, Gold 2.0 vs neutral on photos; Ektar–Velvia pair 1.69). Full table: VERIFY.md.

The verifier judged the S15 amendment (1.40 → 1.80 for Ektar/Velvia) to be goalpost-moving: Velvia boosts muted colours too hard, and a cream cake turns olive-yellow on 2062. It also judged the S37 move to 65³ goalpost-moving relative to what ships today.

## What changed (commits 62f78ab, d4b801a)

`FilmLab.swift`: the chain is rebuilt as a near-straight negative (about 10 stops) feeding a per-stock print curve. The print rolls softly into paper white and paper black, and printer lights are solved per channel so grey prints at 0.18. Film Exposure is inside that solve, so negatives are lab-normalised; Velvia (a slide) keeps exposure as brightness. Push is underexposure plus steeper gamma plus a harder print highlight, with its own pull rates. Velvia push is clamped to −½…+1 in the engine and in `LookPanel.filmLabRows`. Colour rides the stock's tone through the mid-tones, adds per-stock hue lobes, and scales saturation against the sRGB edge before gamut mapping. Portra and Cine get pastel highlights. Tri-X uses panchromatic weights (0.25, 0.55, 0.20).

Tests: the Python mirror in `scripts/gen-fixtures.py` was rewritten and `enginemath.json` regenerated. Film proof floors and records were re-recorded (TEST-CHANGES.md). New `FilmStockLookTests.swift` has 13 tests. There is no separate GPU film kernel: the GPU uses the finish LUT baked from the CPU chain.

## Open items for round 3

1. Fix Film Exposure −2 × Push ≥ +1.5 shadow flood (red channel at 0, shadows brightening as exposure drops). Add a spec line: monotone and near-neutral shadows across the full exposure × push grid.
2. Velvia/Ektar muted-colour gain (S15) needs a human look, and probably a lower gain on low-chroma colours.
3. NEEDS.md: a finer finish table for film plans (owner of the finish table, WS-12). Until it lands, S37 fails at 33³.
4. S38/S39: decide whether Portra and Cine should move further from neutral, accepting a visible cast or lifted blacks.
5. CI: not pushed for macOS CI until now. Check `gpu-parity.yml` and `ci.yml` on this branch when the programme resumes. The new bare `XCTAssert(` adds one item to the swift-surface checker.
