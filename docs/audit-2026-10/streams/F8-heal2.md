# F8-heal2: Heal & Clone, second slice

Stream agent F8-heal2. Base: `origin/claude/jolly-sagan-k7ch7z` plus the F4 branch (a2181a7, f1eb4b6) merged locally, then trunk merged again at the end (clean). Build dir: `/tmp/lumen-build-f8`.

How it was checked: after the final trunk merge, `swift build --build-tests` is clean and `check-swift-surface.py` exits 0. These suites pass: StrokeHeal (11), SpotSourceRepick (4), SpotVisualization (6), RetouchPaste (3), SpotRetouch (16), SpotSection (1), SpotSourceSearch (6), KeyGrammar (11) and SavedLook (17). Before the merge, these also passed: MaskDependency, MaskDependencyAdversarial, BrushSidecar, BlobBackup, WorkspaceModification and ResetSemantics.

LumenApp and LumenPipeline do not build here. Their code is source-verified only.

| # | Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|---|
| 1 | `/` re-picks the selected spot's source | FIXED | 57316e6 | Cycle wrap removed: 1 failure. Both distinctness guards removed: 7. `/` dropped from `dispatchedKeys`: KeyGrammar 1. | none |
| 2 | Visualize Spots (display-only dust view) | FIXED | 2e4c312 | Coarse local mean replaced by the frame mean: the gradient test fails on every interior pixel. A reference added in Kernels.swift: the renderer scan fails. | none |
| 3 | Brushed heal (painted strokes via `strokesRef`/`count`) | FIXED; GPU path source-verified | c0fc8bc | Eight mutants, 312 failures in total: membrane, rim filter, ReferenceRenderer S5, heal ref plumbing, null encode, pixel spacing, version observer. Overlap rule: 82 failures. Effects reset deleting strokes: SpotSection 1. | none |
| 4 | Paste Settings carries spots | FIXED | a332b8f | `out.heal = target.heal` removed: 6 failures. | none |

A recipe without spots or strokes is byte-identical. The empty-heal paths are skipped on both renderers. Mask stroke blobs are byte-identical, which is asserted. No fixture changed.

## Item notes

### 1. `/` re-picks the source
- `SpotSourceSearch.rankedSources` lists the candidates in order. Its first entry is bit-identical to `bestSource` (tested).
- The other candidates must each be at least one radius from all earlier ones.
- `nextSource` is stateless. It reads which candidate the spot is on now and moves to the next one, cycling. A source the user dragged by hand goes to the best candidate.
- The key only acts while the Heal tool is armed; otherwise it falls through.
- No keymap conflict: ⌘/ stays the reference sheet.

### 2. Visualize Spots
- The view is a band-pass of the display luma: a 3×3 box mean minus a 13×13 box mean, drawn inverted.
- Threshold maps to `cutoff = 0.06·0.03^t`.
- It is built as an overlay from the loupe's `PixelSampler`, like the clipping overlay, and is named in `samplerNeeded` and `regionActive`.
- It is not in the recipe or any renderer. A Linux test scans the renderer sources to keep it that way.

### 3. Brushed heal
- Maths and plumbing are in the commit body.
- The GPU uploads the reference's own alpha plane, and the rim positions go up split into high and low parts.
- Parity test: `Tests/LumenPipelineTests/StrokeHealGPUParityTests.swift`, 6 cases × 3 sizes at 1e-3. **It is unrun.** It needs the macOS lane, and the kernels have never been compiled.

### 4. Paste
- `RetouchPaste.develop` keeps the target's own `heal` unless the user opts in.
- The opt-in is a checkable Edit-menu item, "Paste Includes Spot Removal", on `CommandState`, off by default.

## DECISIONS (each implemented the conservative way; overrule freely)
1. **The paste opt-in is a menu checkbox, not a dialog.** There is no paste dialog in this app. Masks were handled by separate commands, so I followed that pattern and did not build a sheet. The setting is session state and is not persisted.
2. **Heal strokes state pipeline version 3**, the same as spots. `statedVersion` now raises on `strokesRef != nil`, because an older build cannot render them. This changes two existing tests:
   - F4's no-spots test now expects 3 for a recipe with a stroke ref.
   - SavedLookTests' "does not downgrade" test now compares against the target's own stated version.
3. **Effects no longer owns `develop.heal`.** That means strokes as well as spots: an Effects Reset would otherwise silently delete painted heal.
4. **Order within S5 is spots first, then strokes in draw order**, on both renderers.
5. **Visualize Spots has no key.** Lightroom's `A` is Auto-advance here. It is a checkbox and slider in the Heal bar.
6. **Brush mode's grammar:**
   - Drag paints a stroke; a click is a dab.
   - Strokes are selected only in Spot mode.
   - ⌫ deletes the selected spot or stroke.
   - `/` applies to spots only.
   - The provisional offset is 2.6 radii perpendicular to the stroke, toward the frame centre.
7. **The heal blob joins the export refusal roster.** A missing heal blob refuses export the same way a missing brush-mask blob does. It uses a synthetic brush component as the predicate carrier.

## FOUND-WHILE-FIXING / NOT DONE
- **The eyedropper taps (`sampleMaskStageInput` and `sampleColorStageInput`) do not render heal strokes.** They build `RenderGraph()` with no stroke sets, so they sample the unhealed pixel under a stroke. The mask source and the render are correct.
- **Strokes have no source drag and no `/` re-pick.** Only the auto offset sets the source.
- **Heal is not "true Poisson" on curved tubes.** The inverse-square membrane is exact for discs and straight strips, and approximately harmonic on bends.
- **Not built:** dust auto-detect, Remove, and the per-pin source transform.
- **In RenderCoordinator, F4's `healAutoSource` sits between `samplePointColorReference`'s doc comment and its function**, so that doc comment now reads as attached to the wrong function. Not touched.
