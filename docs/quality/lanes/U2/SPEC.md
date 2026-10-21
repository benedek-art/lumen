# U2 — slider and control components: acceptance spec

Scope: `LumenSlider`, `LumenTrackStop` (LumenControls.swift), `SliderDrag.swift`, plus the
new `SliderReadout.swift` in LumenCore. Baseline snapshots: `claude-inspiring-dirac-ulgpch/a93efb2`.

## Audit (what the baseline shows)

- A1. `panel-develop-tone.png`, Exposure and Contrast rows: an "L" at the centre of the
  track. Measured from the code: on a ramped track (`trackStops`) the neutral mark is an
  8 pt bar (3 pt black halo + 1 pt white line) running through the 5 pt groove, and the
  deviation underline is a 2 pt rule at y = +4.5 that starts at the same x. The two touch,
  and together draw an L. Reads as a rendering glitch.
- A2. Same image: the Exposure row carries the focus fill edge to edge, flush against the
  "E" of the label. The row is focused with no user action (offscreen window, first
  focusable view); in the app `.focusable()` also takes focus on mouse-down, so every
  click on a slider leaves its row filled until something else is clicked.
- A3. Readout: `String(format: "%.0f", -0.0)` prints `-0`. A drag back to the centre of
  a ±100 control snaps through `(-0.4).rounded() * 1 = -0.0`, so the pill can read `-0`.
  Positive bipolar values have no sign (`24`), where Lightroom prints `+24`, `+0.35`.
- A4. Fine drag (⇧) is a fixed 0.25 gear. On Exposure (±5, step 0.01, 142 pt track)
  coarse is 0.142 pt/step and fine 0.568 pt/step: ⇧ still cannot address single
  hundredths with the track.
- A5. Typing: in the open readout field ↑/↓ do nothing useful (caret moves).
- A6. No pointer feedback at all on the track (the row hover was removed at the owner's
  request; nothing replaced it on the thumb).
- Already correct and kept: relative drag, press-without-movement writes nothing,
  double-click label/track resets through `onReset`, click-to-type with arithmetic,
  ⌥-scroll and trackpad nudge, one-sided soft-limit clamp, AX label/value/adjustable,
  haptic detent at default.

## Measurable lines

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| S1 | Neutral mark never overlaps the groove or the deviation underline | mark bottom ≤ groove top − 1 pt; underline top ≥ groove bottom + 1 pt | `SliderMetricsTests` |
| S2 | Hit target | row ≥ 20 pt tall incl. padding; thumb grab ≥ 20 pt wide | `SliderMetricsTests` |
| S3 | Readout never prints a negative zero | `-0`, `-0.00` impossible for any value, any decimals 0…3 | `SliderReadoutTests` |
| S4 | Signed readout on zero-centred bipolar controls | `+24`, `-38`, `0`, `+0.35`; Temp-like (default ≠ 0) unsigned | `SliderReadoutTests` |
| S5 | Decimals match step at every literal call site | 0 mismatches | audit script in REPORT |
| S6 | Fine gear addresses every step on every linear control at 142 pt | fine ≥ 1.0 pt/step; ±100 controls stay at 0.25 gear (2.84 pt/step) | `FineDragTests` |
| S7 | Coarse drag unchanged | existing `SliderDragTests`, `FineDragTests` pass unchanged | test run |
| S8 | Typing field: ↑/↓ nudge one step, ⇧ ten, one-sided soft clamp | same arithmetic as `SliderTrack.nudged` | `SliderReadoutTests` (entry nudge) |
| S9 | Beyond soft limits held, not evicted | existing `InteractionCorrectnessTests` pass | test run |
| S10 | No write on press without movement | existing `SliderThumbPressTests` pass | test run |
| S11 | AX value equals readout digits (minus sign rule aside) | shared formatter | `SliderReadoutTests` |

## Visual claims (judged from snapshots on this branch vs a93efb2)

- V1. `panel-develop-tone.png`: no L at the centre of Exposure/Contrast; the zero is a
  small tick above the groove, separate from the underline.
- V2. `panel-develop-tone.png`, `column-develop-all-open.png`: no row carries the focus
  fill when nothing was pressed or tabbed to.
- V3. Readouts show `+0.35`, `+12`, `-38`, `+24`.
