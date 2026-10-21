# U2: slider and control components (report)

Branch `quality/u2-slider-component`, head a3b24ed (code). Baseline snapshots are from
`claude-inspiring-dirac-ulgpch/a93efb2`; after snapshots are from `quality-u2-slider-component/a3b24ed`
(36 of 36 rendered, no test failures in log-excerpt).

## For the owner

1. Drag Exposure with ⇧ held. Every hundredth should now land, at 1 pt per step (before: 0.57 pt, so ⇧ skipped values).
2. Click a slider, then press ←/→. The row should not fill grey; a thin ring on the thumb shows which row the arrows move. Press Tab and the fill should come back.
3. Click a value, then press ↑/↓ and ⇧↑/⇧↓. The picture should follow live. Return keeps the value, Esc closes the field (but does not undo the nudges).
4. Open the app and press → straight away. It should page the photo, not nudge Exposure.
5. Hover a track. The thumb grows 1 pt. Say if even that is too much.

## Verdict per spec line

| # | Line | Verdict | Measured |
|---|---|---|---|
| S1 | Zero mark clear of groove and underline | PASS | tick bottom −3.5 pt vs groove top −2.5 (1 pt gap); underline top +4.0 vs groove bottom +2.5 (1.5 pt gap) |
| S2 | Hit target ≥ 20 pt | PASS | row 24 + 2×2 = 28 pt tall; thumb grab 22 pt wide |
| S3 | No negative zero in readout | PASS | 0 cases over decimals 0–3, signed and unsigned (`-0` was reachable: `snapped(-0.4) = -0.0`) |
| S4 | Lightroom signs | PASS | `+0.35`, `+12`, `-38`, `+24`, `0.00`; Temp and 0…100 rows stay unsigned (snapshot confirms) |
| S5 | Decimals match step | PASS | 0 mismatches over all literal call sites (>40 checked; computed ones skipped) |
| S6 | Fine gear reaches every step | PASS | Exposure 0.142 pt/step coarse, now 1.00 fine (was 0.568); ±100 rows 2.84 fine (gear 0.25, unchanged); Tint 1.89 |
| S7 | Coarse drag unchanged | PASS | SliderDrag/FineDrag/ThumbPress suites unchanged and green |
| S8 | ↑/↓ in typing field | PASS (weak) | Uses the same `SliderTrack.nudged` as the arrows, then clamps to the hard range. Only a source check verifies it, because LumenApp has no Linux tests |
| S9 | Soft limits held, not evicted | PASS | InteractionCorrectnessTests green |
| S10 | Press without movement writes nothing | PASS | SliderThumbPressTests green |
| S11 | VoiceOver digits = readout digits | PASS | shared rules; VoiceOver omits the "+" |
| V1 | No "L" | PASS | `evidence/zero-mark-before-after-4x.png` |
| V2 | No focus fill nobody asked for | PASS | `evidence/column-focus-fill-before-after.png` |
| V3 | Signed readouts | PASS | `evidence/tone-panel-before-after.png` |

Verifier: round 1 FAILED because macOS would not compile 93fd592 (`ambiguous use of operator '/'` on the tick
offset, which `swiftc -parse` on Linux cannot catch). Round 2 fixed it in a3b24ed, along with two of its code
findings: the outset fill widened the row's hit area by 6 pt into its neighbours, and Return after ↑/↓ wrote
an empty undo step. The a3b24ed snapshots were then judged against the baseline (crops above). Round 2 confirmed the compile
fix, the hit-target fix and the snapshots, but FAILED the undo fix: `guard next != value` compared Doubles
exactly, and a snapped `0.35000000000000003` never equals the parsed "0.35" (124 of Exposure's 1001 values).
Round 3: `SliderReadout.isNoChange` compares within a thousandth of a step, with a test that walks all 1001
Exposure values.

## What changed and why

- **The "L".** On ramped rows (Exposure, Contrast, Temp, Tint, mixer) the neutral mark was an 8 pt bar through
  the 5 pt groove, a black halo with a white line. The deviation underline started at the same x, 4.5 pt below.
  Together they drew an L. The zero is now a 1×3 pt tick above the groove, in `secondaryText`, the same on every
  row. It sits on panel grey, so it needs no halo. Geometry lives in `SliderMetrics` (LumenCore), with a test.
- **Edge-to-edge highlight.** `.focusable()` takes focus on mouse-down, and the offscreen window gave the first
  slider focus as it opened. The row fill now shows only for keyboard (Tab) focus, 6 pt wider than the
  content so the label isn't flush. Focus from a pointer shows a ring on the thumb. Focus no event asked for is
  refused, so on open the arrows page photos.
- **Readout.** `SliderReadout.text`: never `-0`; `+` on rows centred on zero, as Lightroom does. The field opens
  without the `+`.
- **Fine drag.** `FineDrag.fineGear(for:)` is 0.25 or finer, so a fine step is ≥ 1 pt on linear tracks (lowest
  gear 0.05). Changing gear mid-drag still moves the value by nothing (tested).
- **Hover.** The thumb grows 9 → 10 pt. The row hover fill stays gone, as the owner asked.
- `LayoutMetricSupport.widestReadout` (LumenAppTests) now measures the signed upper bound, because "+" is wider than "-".

## Already right, kept

Relative drag; a release counts as a drag sample; no write on press without movement; double-click on the label or
track resets through `onReset`; click to type with arithmetic; ⌥-scroll and trackpad nudge; arrows with ⇧×10; the
soft-limit clamp only applies on the side the value is moving toward; haptic tick on crossing the default;
VoiceOver label, value and adjustable action; the fill runs from the default.

## Not done / for a human

- Plain two-finger scroll over a slider still scrolls the panel. Changing the value needs ⌥. That is deliberate:
  Lightroom doesn't take the scroll either.
- If focus arrives during a key press (for example a shortcut that switches panels), it counts as keyboard focus.
  Needs a check on a Mac.
- Esc in the typing field doesn't revert ↑/↓ nudges; each one is its own undo step.
- Whether Exposure and Contrast should have ramped tracks at all is BasicPanel's choice, not this lane's.
  Lightroom draws them plain.
- Tests on Linux: 2948 passed. `ControlAccessibilityTests` hangs on Linux on the base commit too. `ControlProofTests`
  ran past the 15-minute local cap. Both run on macOS CI.
