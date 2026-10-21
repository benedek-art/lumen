# T2 tone curves: report (WS-11 parametric, WS-12b point / RGB / luma / Preserve Luminance)

Branch `quality/t2-curves` from `claude/inspiring-dirac-ulgpch` (9068ded). Spec: `SPEC.md`.
Out-of-lane work: `NEEDS.md`. Verifier: round 1 FAIL (6 defects), round 2 conditional
PASS (all 6 fixed, one new minor perf defect and one gesture edge case, both fixed in the
final commit; not re-verified by a third agent).

## For the owner

1. The curve you drag is NOT yet the curve the preview renders: a strong curve is 9–33 codes off (101 on a dip) because the curve is baked into the 33-point colour cube. The fix is built and tested here (`CurveStage`, ≤ 0.003 code) but wiring it into the renderer is WS-01's file (NEEDS N1). Until then, judge strong curves on export, not on the preview.
2. Try by hand: click on the curve (the point lands ON it, nothing moves), drag (no jump when you grab off-centre), hold ⌥ mid-drag (1/10 speed, no jump), double-click a point (deletes), ⌥-click (deletes), drag a point off the graph (deletes).
3. Check the histogram behind the curve stays still while you drag a point, and that on R/G/B it is that channel's, in its colour.
4. Brightening a saturated colour with Preserve Luminance on can still turn its hue (orange +11°); that is the output clamp after the curve, NEEDS N2.
5. Moving a split narrower makes that region's slider weaker (3.5× between the widest and narrowest splits); that is the no-flat-segment limit, kept on purpose. Say if you want the other trade.

Best evidence: `evidence/before-steep-curve-drawn-vs-applied.png` (the blocker),
`evidence/after-histogram-backdrop-on-input-axis.png` (the backdrop fix),
`evidence/after-panel-develop-curve-red.png` (the editor).

## Verdict per spec line

| # | verdict | measured (verifier, rounds 1–2) |
|---|---|---|
| S1 identity | PASS | 0 differing pixels, 3 frames × cube 33/65 × 4 explicit-identity recipes |
| S2 no overshoot | PASS | 1.1e-16 over 3000 random sets |
| S3 CurveStage = exact curve | PASS | ≤ 0.003 code on every audited curve (0.0007 worst in round 1), 0.19–0.30 on the editor's steepest cliff (bound 0.5); NaN/inf safe |
| S4 rendered = drawn at preview size | **FAIL, blocked on NEEDS N1** | cube 33: S 9, steep 33, dip 101 codes; cube 65: 1 / 19 / 81. Unchanged by this lane (renders bit-identical) |
| S5 preview = export | **FAIL, blocked on N1** | 37 codes cube 33 vs 65 on the D850 sky |
| S6 no banding | **FAIL, blocked on N1** | 0 empty histogram bins in sky crops (no 8-bit combing), but cube 33 adds slope corners at lattice nodes, 4× the drawn curve's |
| S7 Preserve Luminance hue | PASS | S-curve: colorchecker \|ΔH\| 0.8° max, hue wheel p95 1.23° |
| S8 RGB curves | PASS | identity exact; R lift moves G/B ≤ 0.06 code |
| S9 parametric live/isolated | PASS | min slope 0.0125 (combined extremes), no dead integer settings, 0.000 code leakage into far zones |
| S10 split bounds shared | PASS | default splits bit-exact; out-of-range splits render as drawn |
| S11 backdrop = curve input | PASS | 6929 S-curve EMD 0.0032 (was 0.064), 2545 0.0025; dip curve now shares its backdrop (21.5 % in x .35–.75 vs truth 30.7 %, was 0 %) |
| S12 placement | PASS | 0 change at the click; ≤ 3 codes elsewhere (spline re-solve, measured 1.9) |
| S13 relative + fine drag | PASS | exact; ⌥ toggled every 7 events never jumps |
| S14 delete gestures | PASS | double-click, ⌥-click, menu, drag-out; anchors never deleted |
| S15 target > ink | PASS | press 10 pt, dot 4 pt (5.5 lit) |
| V1–V3 | PASS (6d38aa2 set) | see below |

Gates: `swift build` clean; all 3057 LumenCoreTests pass on Linux (`--parallel`, as CI);
`gen-fixtures.py --check` passes; `check-swift-surface.py` reports exactly the base
commit's pre-existing findings (its non-zero exit is pre-existing, proven on 9068ded).
To build tests on Linux the toolchain (Swift 6.0) needs a pre-existing trailing comma in
`CompareView.swift` removed; that was done locally only and is not in the branch.

## What changed and why

- **Histogram behind the curve** (`CurveBackdrop`, `CurveEditorView.backdropHeights`). It
  was the delivered picture's histogram, i.e. the curve's OUTPUT, drawn on the input axis:
  20 pt off on a 292 pt plot with an S-curve, 54 pt with a steep one, and it slid under a
  point being dragged. It is now pulled back through the curve stages after the tab's own
  input, per channel on R/G/B. No second render.
- **Placing and dragging** (`CurveEditing.placing`, `DragAnchor`). A click put the point
  under the pointer through `settingPoint`, whose 0.02 snap yanked a nearby point to the
  click height. Now the point is placed on the curve and the drag moves by the hand's
  displacement; ⌥ is a 1/10 fine adjust (Lightroom's modifier) that re-anchors on toggle.
  Double-click deletes (Lightroom), ⌥-click still deletes if it does not travel > 2 pt.
- **Look**: points radius 4 (5.5 and filled when hovered or held), press radius 10;
  eighth grid under the quarter grid; R/G/B tabs tint the trace, backdrop, frame and label,
  and show the other channel curves faintly; histogram fill stronger with an outline.
  Preserve Luminance only under Param and Point, the two tabs whose curve it governs.
- **CurveStage** (`Engine/CurveStage.swift`): the curve as five 8192-sample tables running
  `CurveStack.run`, the body `CurveStack.apply` now shares. Ready for WS-01 to apply after
  the finish cube on CPU and GPU (N1); that is the fix for S4–S6.
- **Split bounds**: the engine read splits with 2–98 % bounds, the editor with 10–90 %;
  the engine now uses the editor's `sanitizedSplits` (Python fixture port updated).

Existing tests changed, and why: `CurveMathTests` pinned the old 8 pt press / 3 pt dot
geometry (now 10 / 4, the new numbers asserted the same way) and listed
`nearestIndexByX` as a call the editor must make (it is now called inside
`CurveEditing.placing`, which the list names instead). `LayoutMetricSupport` slider line
citations renumbered. `PanelSnapshotTests` gained three curve states (appended).
`ParametricReadoutCompatibilityTests` (Darwin-only byte record): cases 6 and 7 re-recorded
from the macOS runner, because their splits lie outside the editor's 10–90 % bounds and
now render as the editor draws them (the split-bounds fix); the eight in-bounds cases are
byte-identical.

CI on f3bc90c: UI snapshots, UI layout, GPU parity, Proof sweep green. CI `test-fast`
failed on exactly those two (slider citations moved by 3 lines; the two re-recorded
hashes), fixed in the next commit. CI `fixtures-linux` fails on `check-swift-surface.py`
with the same findings as the base commit 9068ded (pre-existing; this lane adds none).

## Not fixed / judged

- S4–S6 need N1 (WS-01). N2 (gamut after the curve), N3 (the backdrop disappears when the
  histogram panel is hidden), N4 (RGB curves act on Rec.2020 channels) are in `NEEDS.md`.
- A first Preserve Luminance change (hold chroma instead of scaling it) was made and
  reverted: three existing tests pinned D10's documented semantics (keep saturation), and
  on measurement the hue errors came from the sRGB clamp downstream, not the curve.
- Parametric curvature: y″ jumps at region centres from the raised-cosine crossfade
  (`ZoneWeights`, owned by the tone lane). The slope is continuous; no visible corner.
- Parametric reach (±26–32 codes at ±100) may be weaker than Lightroom's; no Lightroom
  references exist in the corpus, so a human has to judge it.
- Adding a point re-solves the spline around it (≤ 3 codes elsewhere); every interpolating
  spline does this, Lightroom's included. Fritsch–Carlson kept (no overshoot; Lightroom's
  spline overshoots to −0.18/1.18 on the steep set).

## Interaction (cannot be seen in a PNG; reasoned from the code)

Hover lights the point a press would take; the readout shows the held point's in/out
during a drag. The backdrop recompute was measured at 2.1–3.5 ms per hover frame in round
2; the luminance weights are now hoisted out of the 2049-sample loop (the algorithm alone
measured 0.08–0.9 ms). Arrow-key nudging of a selected point (Lightroom has it) is not
implemented.
