# WS-41 Vignette: report

**STATUS: PAUSED by the director during build round 3 of 3. NOT READY TO MERGE.**

- **Done and verified (round 2, commit 627245c):** 31 of 32 lines PASS on an independent verifier's own measurements. The miss is line 18, a hue number re-scoped in Amendment A2 that was never re-verified. GPU parity, UI layout, the macOS build, the macOS tests and the Linux engine tests are all green on CI.
- **Not done:** VERIFY-R2 found three defects outside the spec at that point: Color Priority lift is non-monotone on bright saturated colour, tiny frames (≤ 5 px) lost byte identity, and Paint Overlay lift makes hot pixels in deep shadow. A2 turned these into lines 31–33 and added line 34 for a feather kink. Round 3 started fixing them: commits 8b78716 and f7b5272 plus one uncommitted edit, all saved as WIP on this branch. Round 3 is unverified, and its kernel changes have not been through macOS CI.
- **To resume:** finish round 3 (lines 31–34 and the bookkeeping below), run the verifier, push once. If round 3 fails it is BLOCKED per the lane brief.

## For the owner

1. Vignette now has Lightroom's full set of controls: Style (Highlight Priority, Color Priority, Paint Overlay), Amount, Midpoint, Roundness, Feather and Highlights. It follows the crop, and Feather 0 is a clean edge on any aspect.
2. Old photos render byte-for-byte the same. 52 legacy cases were checked against the old build.
3. Highlights 100 keeps snow and white walls bright under a −4 burn: snow keeps ×0.98 of its lightness, against ×0.33 before.
4. Color Priority keeps a sky blue when lifting corners, where Highlight Priority turns it milky. One fix for bright saturated reds is still in progress.
5. Not mergeable yet: round 3 of 3 was interrupted by the pause.

## Best evidence

- `evidence/after_2545_styles.png`: the three styles at 0 / −2 / +1.5 on the GX85 frame.
- `evidence/after_983_highlights.png`: Highlights 0 / 50 / 100 on the snow frame.
- `evidence/after_6929_midpoint_roundness_grid.png`: a Midpoint × Roundness grid on 6929.

## Verdict per spec line (verifier round 2 at 627245c, plus amendments)

| Lines | What | Verdict | Number |
|---|---|---|---|
| 1–5 | Legacy identity, decode, canonical JSON | PASS | 0/52 mismatches; 48/48 byte-identical vs base build |
| 6–12 | Midpoint / Feather / Roundness geometry | PASS | r50 0.250 / 0.687 / 0.950; feather r50 spread ≤ 0.002; w 0.381 / 0.609; feather-0 edge 2.0 px; circularity 1.002 |
| 13 | Amount monotone in every style | PASS | identical corner codes on grey |
| 14–15 | Highlights | PASS | snow 0.98, sky 0.95, 6929 corner 0.88 |
| 16 | No tone inversion | PASS | 0 reversals |
| 17 | CP burn (A1) | PASS | scene hue 0.00°; float excess over HP ≤ +0.49° |
| 18 | CP lift | FAIL at R2 → re-scoped (A2), not re-verified | clip 0 %; C/C0 ≥ 0.85; skin mid_BR +4.9° 8-bit vs lightness-matched HP +5.0° |
| 19 | Paint Overlay (A1) | PASS | contrast ×0.53 vs HP ×0.66; hue within 0.06° of matched HP |
| 20–23 | Shadow clip, banding, crop | PASS | 42 banding cases with max step 1 code; crop error ≤ 0.023 |
| 24 | GPU parity incl. crop and each style | PASS (CI) | gpu-parity.yml green on 627245c |
| 25–26 | Tests and gates; only named tests changed | PASS | 3080/3080 LumenCoreTests (Linux) |
| 27 | UI rows | PASS (CI) | ui-layout.yml and build-macos green |
| 28–30 | Wiring, feather-0 AA on any aspect, low-end feather | PASS | edge 1.52–1.55 px on 1:1 / 3:2 / 6:1 / 1:6 |
| 31–34 | A2: CP bright-colour monotonicity, tiny-frame identity, PO hot pixels, feather kink | OPEN | round 3 WIP |

## CI

- **627245c:** every job green except `fixtures-linux` → `check-swift-surface`.
- **Why that failure is not this lane's:** its findings are the same as on the base branch. They are `RecipeKeys` Range init, `CommandLine` at `main.swift:147`, `AppState`/`PanelLayout` `set(_:forKey:)` and `LumenType` Font. The scripts-only commit 9748062, which has no Swift changes, fails the same way. The RecipeKeys line numbers moved by 4 only because 4 key rows were added above them.
- **WIP commits:** not run on CI.

## Judgement calls a human should review

- **Amount:** kept in EV (−4…+2), not Lightroom's −100…+100.
- **Feather semantics changed:** Feather now sets width only around the Midpoint, as in Lightroom. Recipes with feather ≠ 50 render differently. The tests that pinned the old meaning were updated, with reasons given in the commits.
- **Amendments A1 and A2:** they replaced absolute display-hue limits with lightness-matched comparisons against Highlight Priority. The evidence is that every style holds scene hue to 0.00°, and the remaining shift is the display transform (another lane) acting at a lower lightness.
- **Legacy protection kept:** the old fixed 0.5 highlight protection above scene Y 2.88 stays at Highlights 0 to keep byte identity. It is unreachable on real photos (0 corpus pixels).

## Bookkeeping open for round 3

- The `testInnerRadiusIsMonotoneAndBounded` tolerance (1e-12 → 1e-6) needs a stated reason or a revert.
- NEEDS.md says the kernel has 21 arguments; it now has 26.
- BUILD-NOTES gives 0.017 for line 22; the verifier measured 0.023.

Files: AUDIT.md, SPEC.md (with A1 and A2), BUILD-NOTES.md, VERIFY.md, VERIFY-R2.md, NEEDS.md.
