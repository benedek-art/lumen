# WS-45 / WS-46 report: linear and radial gradients (lane M3)

Branch `quality/m3-gradient-masks`, from `claude/inspiring-dirac-ulgpch` @ 9068ded.
Spec: `SPEC.md`. Audit (before): `audit/AUDIT.md`. Cross-lane asks: `NEEDS.md`.

## For the owner (try these by hand)

1. Linear: drag from the top of a sky down to the horizon. The sky should darken, not the ground (it used to be the ground).
2. Linear: drag an outer line. Both outer lines should spread around a fixed centre line. ⌥-drag moves one line. Drag the centre line away from the pin to turn it.
3. Radial: drag from the subject outward. It now draws from the centre, and ⌥ draws corner to corner. Check that the rim, inner ring and centre are grabbable at fit, 1:1 and 4:1.
4. Radial at Feather 0 on a rotated crop: the edge should be smooth, and the drawn rim should sit on the red overlay's edge.
5. Drag speed on a 45 MP file: still unmeasured here (no Mac). Tell me if a gradient trails the hand.

## Verdict per spec line

Verifier: round 1 FAIL (three defects, all fixed in f2258be), round 2 PASS. Numbers are the
verifier's own measurements unless noted.

| # | Verdict | Measured |
|---|---|---|
| S1 full effect at the press | PASS | alpha 1.000 at the press, 0.000 at the release (test and render) |
| S2 three-line grammar | PASS | on a 500 pt gradient at 0/30/90/137°: pin ±11 pt moves, centre line ±11 pt turns, outer lines ±11 pt feather, strip moves from 11 to 489 pt |
| S3 symmetric feather | PASS | midpoint fixed exactly, span changes by exactly 2 × slide, ⌥ leaves the far line fixed, 11.0 pt floor in both modes (±1000 pt slides) |
| S4 short gradient keeps a move target | PASS | move strip 22 pt at 44 pt, 44 pt at 65.9 pt, about 2 × 10.75 pt at 66 pt; never 0 (round 1 hit 0 pt at 44 pt, fixed by moving the centre line's threshold to 6 grab radii) |
| S5 radial from the centre | PASS | centre = press, radii = drag per axis, ⌥ draws the bounding box |
| S6 Feather 0 anti-aliased in every direction | PASS | 3:2 frame at 30°: 2514 partial px on a 2158 px rim, against 0 before the change; 1000 × 20 px ellipse: 2 px at each long-axis end (round 1 had 75 px), 1 px at each short-axis end; radii of 1–4 px give no NaN |
| S7 sub-1.5 px linear | PASS | a 0.05 px span renders 1 intermediate code; zero length renders as no mask (CPU and GPU) |
| S8 linear alpha on its three lines | PASS | max \|α − expected\| 0.0028 on the exact plane, 0.0044 through 8-bit; the auditor found the α = 0.5 line 0.6 px from the drawn centre line and tilted 0.002° |
| S9 radial rim and ring where drawn | PASS | 32 rays: α ≤ 0.00 at 1.5 px outside the rim, ≥ 1.00 at 1.5 px inside the ring; the auditor fitted 460.78 × 153.60 px at 29.997° against 460.8 × 153.6 at 30° |
| S10 the source-to-display map is a similarity | PASS by reading; the test runs on macOS CI | flip + rotate + translate; `GradientDisplayMappingTests` asserts 90° ± 0.01° |
| S11 outline within 0.25 pt at any zoom | PASS | sagitta ≤ 0.25 pt for radii up to 20 000 pt (4096-step cap) |
| S12 monotone, C1 falloff | PASS | all profiles monotone; largest step per pixel: linear 1, F25 5, F50 3, F100 2 codes, all within threshold |
| S13 perceptually even | **BLOCKED** (fails as measured) | t50 is 0.561 at −2 EV and 0.337 at +2 EV, against a threshold of ±0.08. Cause: scene-linear blending in S11, which this lane does not own (NEEDS N1) |
| S14 no banding in 8-bit skies | PASS | longest constant-code run, masked against unmasked: 983 14/13 (1.08×), 1840 16/22 (0.73×); dither removes the 1-code contours |
| V1/V2 snapshots | PASS | `quality-m3-gradient-masks/f2258be/window-1512x982-masking-linear.png` and `-masking-overlay.png` on the `ui-snapshots` branch |
| V3 Feather 0 edge | PASS | `evidence/radial-feather0-before-after.png` |

## What changed and why

**Linear: the three-line handle** (`MaskHandles.linearGrab`, `MaskCanvas.drawLine`). The gradient was two outer lines plus a short axis segment between the end dots, and turning lived on an undrawn band outside the strip. It is now Lightroom's handle. Three lines run across the photo and are clipped to it. The pin moves the gradient, the centre line (±11 pt, away from the pin) turns it about the pin, and each outer line feathers. The end dots keep their old job of swinging one end. Below 66 pt of span (six grab radii) the centre line is not offered, so a short gradient keeps its move target (`centreLineMinimumLength`). Unselected gradients now draw a faint centre line instead of the axis stub, which was the stray vertical hairline in the baseline masking snapshot.

**Linear: symmetric feather** (`MaskHandles.featheredLine`). Dragging an outer line used to move only that endpoint, so the aim moved with it. Now both lines move about a fixed centre line, and ⌥ moves one line as before. The span floor stays at 11 pt.

**Linear: full effect at the press** (`MaskHandles.drawnGradient`). `linearPlane` puts alpha 0 at `line[0..1]`, and the create gesture stored the press there. So the standard Lightroom gesture, dragging down from the sky to the horizon, darkened the ground. The audit hit this independently: its "sky" recipe flattened the sky's natural gradient from about 12 codes to about 4, with runs up to 90 rows. Only new gradients change. Stored recipes render exactly as before, and the Colour Pick line keeps its old order. The snapshot fixture's "Sky" mask (`[0.5, 0, 0.5, 0.55]`, −0.4 EV) was written in the old order and darkens below its centre line. I left it alone so the baseline snapshots stay comparable.

**Radial: drawn from the centre** (`MaskHandles.drawnEllipse`). This matches Lightroom. ⌥ now draws the bounding box, which used to be the default.

**Radial: outline accuracy at zoom** (`MaskHandles.ellipseSteps`). The rim was always 72 segments. At 1:1 on a big ellipse that sits 5 pt off the rendered rim, which is half a grab radius. The segment count is now chosen so the outline stays within 0.25 pt at any zoom.

**Rendering: anti-aliased hard edges** (`MaskRaster.radialCore`/`radialRampStart`, `linearPlane`, `maskRadialSource`/`maskLinearSource`, `MaskGPU`). At Feather 0 the radial ramp was 1e-6 of the radius wide, so the rim was a stair-step: 0 partial pixels on a 965 px rim, with 77 to 89 code jumps. The ramp is now at least 1.5 px wide in every direction, set per pixel from |∇r|, which gives 1356 partial pixels on the same rim. Round 1 set the floor on the short axis only, which left a 1000 × 20 px ellipse 75 px soft at the ends of its long axis. The verifier caught it and it is fixed. 1.5 px because a smoothstep's peak slope is 1.5/width, so 1.5 px matches one pixel of box-filter coverage. One pixel looked half-aliased at 12×. A linear span under 1.5 px is widened about its centre line. The CPU and the shader share one `rin` function and compute the per-pixel floor with the same expression. Evidence: `evidence/radial-feather0-before-after.png`.

**Polygon (WS-46).** I changed no code. Its feather is centred on the outline, Feather 0 is already a 1 px ramp, and `PolygonMaskTests` (15 tests) pass. Drawing and drag latency of the lasso are not measurable here.

## Tests changed

- `MaskHandlesTests.testAnywhereInTheBandMoves`: rows within 11 pt of the centre line are excluded, because that band now turns the gradient (S2). The pin at x = 800 is still asserted to move.
- `MaskingTests.testAMasksCurveIsAppliedToTheFormedPictureThroughItsAlpha`: now checks only pixels where alpha = 1. Its "hard" radial has a 1.5 px anti-aliased rim now, and rim pixels carry a partial curve by design.
- `MaskEdgeShiftTests.testTheTransitionBandCannotSeeAHardEdge`: asserted that the band statistic cannot see a Feather 0 edge, and its message said to update the file if that ever changed. It changed: 0.27 for the soft radial against 2.80 with the hard one at 320². The test now asserts that. The boundary statistic the fix relies on is unchanged and still passes.

New: `GradientLaneTests` (9, Linux) and `GradientDisplayMappingTests` (2, macOS CI). The snapshot suite gains `window-1512x982-masking-linear`, appended.

## Could not fix in this lane

- S13, perceptual evenness at +2 EV, is BLOCKED. The local blend is linear in scene-linear (S11, owned by WS-01/WS-42), which puts the visible midpoint of a +2 EV gradient 16% of its span off-centre. Exposure scaled by alpha in EV, as Lightroom does, would bring it within 4%. See `NEEDS.md` N1.
- `swift test` does not build on the Linux 6.0.3 toolchain at the base commit: `CompareView.swift` has trailing commas in two calls. I patched it locally to run the suite and did not commit the patch. `NEEDS.md` N2.

## Gates

- `swift build --target LumenCore --target LumenRender`: clean.
- Linux `swift test --filter LumenCoreTests --skip ControlProofTests`: 3053 tests. The only failures were two tests pinned to the aliased Feather 0 edge; both were updated (see above), and the verifier re-ran the whole suite on b1565c1 with no failures. Mask/gradient filter (398 tests): 0 failures on f2258be. This needs the local CompareView comma patch (NEEDS N2).
- macOS on f2258be (the code head; later commits are docs only): GPU parity **success** (includes `MaskGPUParityTests` and the new `GradientDisplayMappingTests`), UI snapshots **success**, Proof sweep **success**. CI and UI layout were still queued at 03:15 UTC (the macOS queue is about 50 runs deep), so they have **not reported**.
- Verifier: round 1 FAIL, round 2 PASS.
- Snapshots (`ui-snapshots`, `quality-m3-gradient-masks/f2258be/`): `window-1512x982-masking-linear.png` shows the three lines across the photo, clipped to it, with the pin on the centre line and the red wash lined up with the outer lines (V1 PASS). `window-1512x982-masking-overlay.png`: the unselected Sky gradient draws a faint horizontal centre line where the baseline had a vertical axis hairline (V2 PASS).

## Evidence (best three)

1. `evidence/sky-drag-direction.png`: the same top-down drag at −1.5 EV, shipped (ground darkened) next to this lane (sky darkened), on 1840 and 983.
2. `evidence/radial-feather0-before-after.png`: Feather 0 rim at 12×, stair-step against a 1.5 px anti-aliased edge.
3. `audit/alignment_3x2_rot30.png`: a rotated 30° ellipse and a diagonal gradient on a 3:2 frame. The rendered alpha sits on the drawn geometry to 0.6 px and 0.003°.
