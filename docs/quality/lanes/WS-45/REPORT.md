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

VERDICT_TABLE

## What changed and why

**Linear: the three-line handle** (`MaskHandles.linearGrab`, `MaskCanvas.drawLine`). The gradient was two outer lines plus a short axis segment between the end dots, and turning lived on an undrawn band outside the strip. It is now Lightroom's handle. Three lines run across the photo and are clipped to it. The pin moves the gradient, the centre line (±11 pt, away from the pin) turns it about the pin, and each outer line feathers. The end dots keep their old job of swinging one end. Below 44 pt of span the centre line is not offered, so a short gradient keeps its move target (`centreLineMinimumLength`). Unselected gradients now draw a faint centre line instead of the axis stub, which was the stray vertical hairline in the baseline masking snapshot.

**Linear: symmetric feather** (`MaskHandles.featheredLine`). Dragging an outer line used to move only that endpoint, so the aim moved with it. Now both lines move about a fixed centre line, and ⌥ moves one line as before. The span floor stays at 11 pt.

**Linear: full effect at the press** (`MaskHandles.drawnGradient`). `linearPlane` puts alpha 0 at `line[0..1]`, and the create gesture stored the press there. So the standard Lightroom gesture, dragging down from the sky to the horizon, darkened the ground. The audit hit this independently: its "sky" recipe flattened the sky's natural gradient from about 12 codes to about 4, with runs up to 90 rows. Only new gradients change. Stored recipes render exactly as before, and the Colour Pick line keeps its old order. The snapshot fixture's "Sky" mask (`[0.5, 0, 0.5, 0.55]`, −0.4 EV) was written in the old order and darkens below its centre line. I left it alone so the baseline snapshots stay comparable.

**Radial: drawn from the centre** (`MaskHandles.drawnEllipse`). This matches Lightroom. ⌥ now draws the bounding box, which used to be the default.

**Radial: outline accuracy at zoom** (`MaskHandles.ellipseSteps`). The rim was always 72 segments. At 1:1 on a big ellipse that sits 5 pt off the rendered rim, which is half a grab radius. The segment count is now chosen so the outline stays within 0.25 pt at any zoom.

**Rendering: anti-aliased hard edges** (`MaskRaster.radialCore`, `linearPlane`, `maskLinearSource`, `MaskGPU`). At Feather 0 the radial ramp was 1e-6 of the radius wide, so the rim was a stair-step: 0 partial pixels on a 965 px rim, with 77 to 89 code jumps. The ramp is now at least 1.5 px wide on the shorter axis, which gives 1356 partial pixels on the same rim. 1.5 px because a smoothstep's peak slope is 1.5/width, so 1.5 px matches one pixel of box-filter coverage. One pixel looked half-aliased at 12×. A linear span under 1.5 px is widened about its centre line. The CPU and the shader use one `rin` function, so they cannot drift apart. Evidence: `evidence/radial-feather0-before-after.png`.

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

GATES

## Evidence (best three)

1. `evidence/sky-drag-direction.png`: the same top-down drag at −1.5 EV, shipped (ground darkened) next to this lane (sky darkened), on 1840 and 983.
2. `evidence/radial-feather0-before-after.png`: Feather 0 rim at 12×, stair-step against a 1.5 px anti-aliased edge.
3. `audit/alignment_3x2_rot30.png`: a rotated 30° ellipse and a diagonal gradient on a 3:2 frame. The rendered alpha sits on the drawn geometry to 0.6 px and 0.003°.
