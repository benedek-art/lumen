# WS-14 Texture and Clarity: report

**STATUS (paused by the director, mid round 2): NOT VERIFIED.** The tip commit is unverified round-2 work in progress, and its GPU edit may be incomplete. Verifier round 1 on `e406d6e` returned **FAIL**: 46 of 51 spec lines passed, and M7, P1, P2, B3, R5 and G5 failed. macOS GPU parity on `e406d6e` showed GPU/CPU 0.993-1.001 on every probe, but 2 tests failed because the round-1 gate shut their content. To resume, finish the builder's round 2 against SPEC §15, then send it to a fresh verifier.

## For the owner

- Both controls were broken before this lane. Clarity was effectively dead on real photos (gain 1.00-1.02) and posterized at +100. Texture worked on the wrong band (21 px instead of 4-16 px periods at 24 MP) and flipped sign in small previews. The GPU ran a different algorithm from the CPU reference.
- Round 1 rebuilt both controls as frame-relative bands, identical on CPU and GPU. Halos dropped (Texture overshoot went from 40% to 0%) and preview now matches export. Skin smoothing passes.
- What still fails: round 1 stopped Texture from touching oriented detail like hair, grass or wood grain above about 0.2 EV, and Clarity is still weaker than Lightroom on edge-heavy photos. Round 2 targets both and is unfinished.
- Do not merge the tip as-is. `e406d6e` is the last coherent state, but it failed verification.

## History

| Commit | What | Verified |
|---|---|---|
| `e75523c` | SPEC.md and measurement tools | n/a |
| `e406d6e` | Round 1 build (CPU and GPU) | Verifier FAIL, macOS parity 2 tests red |
| `2827fba` | Spec amendments §15 (S9 oriented texture, H8 Clarity corners, R5a, U11 test runtime, G2b real GPU probes) | n/a |
| tip | Round 2 work in progress (paused) | no |

## Round-1 verifier numbers (`e406d6e`)

- **Pass:** S1-S8 (Texture peak 867 cpi, gain at 750 cpi 1.87 / 0.25; Clarity peak 55 cpi, gain at 60 cpi 1.79 / 0.34), M1-M6, M8, P3, B1, B2, B4, C1-C3, H1-H7, Q1-Q4, N1, N2, K1-K7, R1-R4, G1, G3, G4.
- **Fail:**
  - M7: 983 Texture ±25 gives |g−1| = 0.015.
  - P1: Texture +100 median 1.345 against 1.40 needed. This passed on base, so it is a regression.
  - P2: Clarity +100 median 1.21.
  - B3: one block on 1569 moves 2.42 codes.
  - R5: 983 correlation 0.64, a measurement-floor case that SPEC §15 addresses.
  - G5: one robustness test's amplitude was lowered. Round 2 restores it.
- **Not yet measured:** the §15 lines. On `e406d6e`, S9, H8, U11 and G2b fail.

Full details are in BUILD-NOTES.md and in the spec's baseline columns.

## Evidence

The three best images are `evidence/V1_skin_after.png` (before: `V1_skin_before.png`), `evidence/V2_lantern_after.png` and `evidence/V3_preview_after.png`. All are round-1 renders.
