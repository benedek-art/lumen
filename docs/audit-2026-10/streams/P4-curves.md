# P4-curves — tone curves and edit history

Branch: `worktree-agent-af87afd3d967f7c61`, on `claude/jolly-sagan-k7ch7z` at cc4cdd7.
Inputs: Astra findings AI-04 and AI-05, SUPPLEMENTAL-BACKLOG S-05 and S-06 (the eight
CurveAdversarial expectations), and the September A2-12 note.

| Item | Status | Commit | Proof records that move |
|---|---|---|---|
| AI-04 luma black lift: discontinuous, purple on the GPU | FIXED | baca375 | none |
| AI-04 follow-on: the master point curve had the same defect | FIXED | baf9c96 | none |
| AI-05 point handles off the composite trace | FIXED | 099ba96 | none (UI only) |
| S-05 two deletions at one index were one Undo | FIXED | 938f17d | none |
| S-06 group-move exactness and malformed state | FIXED (contract defined) | ff49fff | none |
| A2-12 coalescing window 1.2 s against docs/12 §12.10's 2 s | NOT CHANGED (decision recorded) | — | — |

All eight CurveAdversarial `XCTExpectFailure` expectations are gone: one in S-05 and six
in S-06, eight assertions in total. Each of those tests now runs on Linux too; before,
they returned early there.

Local checks: `swift build --build-tests` is clean. These suites are green: CurveBlackLift,
CurveCompositeHandle, CurveMath, CurveAdversarial, Engine, LocalStageReferenceContract,
Masking, Robustness, ScaleHonesty, AccuracyProbe, PlanTableCache, ResetSemantics,
SliderContract and ProofSmoke. `scripts/check-swift-surface.py` exits 0. The LumenApp and
LumenPipeline tests are source-verified only.

---

## AI-04 — a luma curve that lifts black (baca375)

**Mechanism.** `CurveStack.apply` ran the luma stage as `e · f(L)/L` and skipped any pixel with
`L ≤ 1e-6`. With `f(0) = b > 0`, black therefore stayed black, while a pixel just above it
jumped to the lift. Next to black, `b/L` is huge. The finish cube's dark coloured corners
came out as saturated primaries, and Core Image's trilinear `CIColorCube` mixed them into the
neutral diagonal.

**Fix.** The new function `CurveStack.liftedLuma` is used only when `f(0) > 0`. Below the
lift it applies `e·(f(L) − b)/L + b`: the black lift is added as grey, and only the rest of
the rise is applied as a ratio. That ratio tends to the curve's slope at L = 0, so the
output is continuous into black, where it is exactly `(b, b, b)`. Luminance stays `f(L)`,
and neutrals come out identical to the ratio form. From `L = b` upward the old ratio form
runs unchanged, and a smoothstep in `L/b` joins the two. A curve that does not lift black
never reaches this function and is bit-identical; a test restates the old arithmetic and
checks this over 2000 random colours. The fix is in `CurveStack`, so it covers both
renderers: the finish cube (`finishLUT`) and the mask curve table (`LocalCurvePlan`) are
both baked from it, and so is `exactColor`.

**Evidence.** The test samples `finishLUT` the way `CIColorCube` does (trilinear) at size 33
and scene 1e-8:
- Before: `[.026817, .006053, .067412]`. The audit measured `[.027359, .006368, .067010]`.
- After: neutral within 2% of the exact value, .033596.
- The reference path (tetrahedral) was neutral before, but gave .00257 against .0336.

**Red/green.** CurveBlackLiftTests is a new Linux suite. With the fix substituted out, 3 of
5 tests are red, with 9, 1 and 14 failures. With the fix, all are green.
CurveBlackLiftGPUTests is a new macOS suite that renders through the real `RenderGraph` at
sizes 33 and 65. It is source-verified: traced against the old code, it gives the audit's
purple.

## AI-04 follow-on — master curve under Preserve Luminance (baf9c96)

I found this while fixing AI-04. The master curve uses the same `e·f(L)/L` form when
Preserve Luminance is on, which is the default. A point curve `[[0,.2],[1,1]]` gave a GPU
neutral of `[.0529, .0321, .0935]` against .0336. A red pixel at 1e-6 rendered 0.54 red,
beside a black that renders as 0.033 grey. The master branch now uses the same
`liftedLuma` function when `masterBlack > 0`. With that branch substituted out, 2 of 6
tests are red, with 3 and 10 failures. The macOS GPU test covers both curves.

## AI-05 — point handles on the composite trace (099ba96)

The Point graph draws the composite trace, `point(parametric(x))`. Handles were drawn,
hit-tested and dragged in the point curve's raw coordinates. `CurveStack` gains three
functions:
- `pointInput(atCompositeX:)`, which is the parametric curve;
- `compositeX(atPointInput:)`, its inverse, found by bisection (on a plateau it takes the
  left end);
- `compositeHandles`.

`CurveEditorView` now draws and hit-tests `plottedPoints`, and stores every placed or
dragged x through `storedX`. The drag readout shows the handle's composite x. Only the Point
channel changes. Without a parametric edit, the maps are exactly the identity.

- **Red/green:** CurveCompositeHandleTests is a new Linux suite with 7 tests. With the maps
  replaced by pass-throughs, 3 are red, and the failure reproduces the audit's 16.963 px.
  All 7 are green with the fix.
- **Source scan:** a new CurveMathTests case strips comments and checks the editor's
  source. Against the old editor, 5 assertions are red.
- **Also fixed:** `CurveStack.nudged` (the target-adjustment drag) had the same axis
  mix-up. It has no caller yet.

## S-05 — deletion history (938f17d)

Deletions used the key `<prefix>delete.<channel>.<index>`. Deleting index 1 moves the next
point into slot 1, so a second deletion at the same spot reused the key and folded into
the same undo step. A deletion now records with no coalescing key
(`CurveEditing.deletionCoalescingKey = nil`) and the label "Delete Point", the same way
mask deletion records.

What still coalesces:
- A drag-out that ends in a deletion is still one step with its drag, because both happen
  inside the same gesture epoch. A test pins this.
- Placing a point and then dragging it shares the point's key, so it is unchanged.

Tests:
- **CurveAdversarial (Linux):** the test now uses real `CurveEditing.deleting` edits
  recorded under the editor's own constant, through the same `HistoryCoalescing` rule that
  `HistoryStack` uses. No key strings are made up. With the old key substituted back, 2
  assertions are red: there is 1 step instead of 2, and undo restores 3 points instead
  of 4.
- **CurveDeletionHistoryTests (macOS):** a new suite that drives the real `HistoryStack`:
  - two deletions become two steps, and undoing them restores one point at a time;
  - two deletions from the context menu also become two steps;
  - placing a point and dragging it over ten events is one step.

  It is source-verified: with the old key it records one step.

## S-06 — group-move contract (ff49fff)

`GroupMove.moved` now states the legal-state contract:
- A move starts from `GroupMove.legal(values)`. Non-finite values read as 0, the same way
  `mean` already read them. Out-of-range values clamp to their rail. A residue within
  1e-12 of the range of zero (2e-10 for ±100) becomes exactly 0.
- From a legal set, a move is rigid and reversible to round-off. Zero comes back exactly,
  so the Reset dot clears.
- An inverted range is refused.

`ColorPanel`'s All-bands row now reads both its displayed mean and its drag from the legal
set, so the number shown and the set moved agree. Any set this app writes is already legal,
so `legal` changes nothing for it.

"NaN refused on decode" was already true. `CanonicalJSON.decodeRecipe` rejects NaN, nan,
Infinity, -Infinity and 1e400 in a mixer band. A new test pins this. It passes on the old
code, because it pins existing behaviour rather than a fix.

**Assertions.**
- Reworded to a tolerance: the two bit-exact assertions (round trip, rigidity) now allow
  1e-12. They pass on the old code, as they should. With a per-band clamp substituted in
  (`v + requested`), both go red, so they can still fail.
- Kept exact: the zero round trip.
- With `legal` as the identity and the snap at 0, 4 tests and 9 assertions are red. Zero
  comes home as −7.105e-15, which is the audit's figure.
- The existing expectation for `CurveMathTests.testAnOutOfRangeBandFromASidecarCanStillBeDraggedBack`
  changes from `[100, −10, …]` to `[90, −10, …]`, and the way back is now asserted.

## A2-12 — coalescing window

The constant is unchanged. See DECISIONS.

---

## DECISIONS

1. **A2-12: which document should change.** docs/12 §12.10 says "N nudges of one slider
   within 2 s = one entry", and that should stay as the contract. The code should follow
   it: `HistoryStack.coalescingWindow` should become 2.0, and the comments that quote
   "1.2 s" should change with it. Those comments are in `HistoryCoalescing.swift`, in
   `CurveEditing.pointCoalescingKey` and in `CurveEditorView.pointKey`.

   The reason: drags are now made one step by gesture epoch, not by the window (A2-02 has
   landed). The window now only governs repeated edits outside a gesture, such as keyboard
   nudges, scroll nudges and typed entry, and that is the case §12.10's HIG reference is
   about. If you prefer 1.2 s, amend docs/12 §12.10 instead, at line 590. Either way it is
   your call on how undo should feel, so I did not change it.
2. **AI-04 shape.** Below the lift, black is lifted with grey. Pixels with luminance at or
   above the lift (`L ≥ b`) keep the old ratio form exactly. This changes the look only of
   existing edits that lift black on the luma curve, or on the master curve with Preserve
   Luminance on, and only for pixels below the lift. Those are exactly the pixels that
   used to go wildly saturated or discontinuous. The other option, a neutral lift
   everywhere, would also desaturate mid-tones of such edits, so I did not implement it.
3. **AI-05 direction.** I kept the composite trace, as before, and moved the handles onto
   it. The finding's other option was to show the Point graph in the point curve's own
   input domain. That would change what the graph draws, so I did not take it. One visible
   consequence: with a point curve set, moving a parametric slider now slides the Point
   handles sideways. That is the true composition.
4. **S-05 label.** Deletions now appear as "Delete Point" in the Edit menu and the history
   list. Before, they appeared as "Undo Edit" and as a derived "Point".
5. **S-06 legal-state semantics.** Out-of-range values are clamped to their rail on first
   touch, NaN and ±inf read as 0, and residue within 2e-10 of zero becomes 0. A set whose
   spread is wider than the range becomes `[-100, 100]` on first touch, and then has no
   room to move.

## FOUND-WHILE-FIXING

- The master curve under Preserve Luminance had the same defect as AI-04. It is fixed in
  baf9c96.
- `CurveStack.nudged` stored the picture x as the point x. It is fixed in 099ba96 and has
  no caller yet.
- The CPU `LUT3D.sample` is tetrahedral, but the GPU's `CIColorCube` is trilinear. A neutral
  check that only uses `finishedColor` cannot see a GPU cast. CurveBlackLiftTests restates
  the trilinear filter for that reason. Other neutral-on-GPU checks may have the same blind
  spot.
- The scratchpad directory is shared with another stream. Once, my run of
  `scratchpad/suites.sh` executed P3's file of the same name, which builds and tests in
  `/tmp/lumen-build-p3` against their worktree. It changed no source, but P3's build cache
  may have been touched.
