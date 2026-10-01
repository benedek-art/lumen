# F4-heal: spot removal, first slice (Heal and Clone)

Stream agent F4-heal. Base: `origin/claude/jolly-sagan-k7ch7z` @ 0896556. Build dir `/tmp/lumen-build-f4`.
Inputs: README Phase 8, docs/09 §Heal / Clone, docs/12 §12.3, docs/14 §2 (S5), docs/15 §15.4, docs/16 Phase 8, docs/29.

How it was checked: `swift build --build-tests` is clean and `check-swift-surface.py` exits 0. These LumenCore suites pass: SpotRetouch (16), SpotSourceSearch (6), SpotHandles (3), SpotSection (1), KeyGrammar (11), KernelRoster (2), Catalog (63), SidecarNewerFormat (5), RecipeCodecTolerance (7), CanonicalJSON (14), DesignSystem (16), GrainParityScan (8), ResetSemantics (14), WorkspaceModification (19), SavedLook (17) and InspectionHold (17).
LumenPipeline and LumenApp do not build on Linux. Their code is source-verified only.

## What was built

| Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|
| Recipe format: `develop.heal.spots`, version stamp, newer-build guards, XMP round trip | DONE | a2181a7 | Version observer removed: 4 failures. Empty list encoded: 1 failure (`default-recipe.json` fixture). Sidecar guard back on `currentPipelineVersion`: 2 failures. | none |
| S5 retouch in the CPU reference (`SpotRetouch`) | DONE | a2181a7 | S5 removed from `ReferenceRenderer`: 2 failures. Membrane removed (Heal becomes Clone): 2 failures. | none |
| S5 in the GPU graph (`RenderGraph.applySpots`, 2 kernels) | DONE, GPU parity untested here | a2181a7 | `SpotRetouchGPUParityTests`: 5 spot cases × 3 sizes at 1e-3, plus "outside the box is the input's own bytes" and "S5 before S6". macOS only, source-verified. | none |
| Auto source (`SpotSourceSearch`) | DONE | a2181a7 | Pattern search removed: 1 failure (two-axis phase). Interior penalty removed: 2 failures (dot-in-source). | none |
| Heal tool in the app (`Q`, `HealCanvas`, `HealToolBar`, ⌫, Esc) | DONE, source-verified | f1eb4b6 | KeyGrammarTests reads Keymap.swift on Linux: green. The press grammar is `SpotHandles` (LumenCore, 3 tests). | none |
| A recipe without spots renders byte-identically | DONE | a2181a7 | `testNoSpotsIsByteIdentity` and `testARecipeWithoutSpotsEncodesExactlyAsBefore`. The CPU and GPU stages are both skipped for an empty list. The fixtures and fingerprints are unchanged. | none |

No proof record moves. Before this, no recipe could carry spots. Every stage and encoding change is identity for a recipe without them.

### Heal maths

- **Heal** is the gradient-domain (Poisson, Pérez 2003) solution, computed in closed form: `fill = I(p + d) + M(p)`.
- **The membrane `M`** is the harmonic interpolant of the rim difference `I_dst − I_src` on the disc. This is the Poisson integral. It is discretized at 64 rim samples, and each sample is the mean of 4 points along its arc.
- **The weights** are `1/|q − u_k|²`, normalized. The `(1−ρ²)` factor cancels.
- **Why closed form:** it needs no iterative solver and no convergence tolerance, so the GPU kernels can do the same arithmetic. That is why it was chosen over a solver or a mean-and-variance blend.
- **Tests:**
  - A linear ramp is harmonic, so Heal reproduces it to within 1e-5. Clone from the same source is off by 0.15.
  - A slope that the source lacks is rebuilt to within 0.004.
  - A boundary of cos θ comes back as x, to within 1e-3.
- **Clone** is `I(p + d)`.
- **Edge:** `alpha = opacity·(1 − smoothstep(rin, 1, ρ))`. This is the radial mask's core rule, including its one-pixel guard. Pixels at or beyond the radius are never written.

### Pipeline position

- **CPU:** first in `ReferenceRenderer.render`. Its input has already been through S3 upstream.
- **GPU:** in `RenderGraph.colorStageInput`, straight after `applyDenoise`.
- **Mask source:** the GPU stage also runs in the mask source, matching the reference's S11 input. `maskSourceFingerprint` now keys `develop.heal` for that reason.
- **Resolution independence:** positions are fractions of width and height, and the radius is a fraction of the long edge. Tested: the 1x render and the box-downsampled 2x render agree to within 0.02, and the resolved geometry scales exactly.

## DECISIONS (each implemented in the conservative direction; overrule freely)

1. **Spots are stored inline in the recipe, not in a blob.** docs/15 rule 4 sends heal *stroke vectors* to content-addressed blobs. A circular spot is seven numbers, which is smaller than a blob ref. `strokesRef`/`count` stay reserved for painted heal. docs/15's example row `"heal": {"strokesRef", "count"}` should gain `spots` if you agree.
2. **Versioning uses two constants, not one global bump.**
   - `currentPipelineVersion` stays 2: the stamp on `Recipe()`, the sidecar default and the cache keys.
   - New `supportedPipelineVersion = 3` is what every newer-build guard now compares.
   - A recipe states 3 only once it carries spots. This is enforced by an observer on `Recipe.develop` and by the memberwise init. The decoder reports whatever the document says, per the RecipeDecoding rule that `RecipeCodecToleranceTests` enforces.
   - Effect: no fixture, fingerprint or artifact cache changes, and a v2 build keeps full write access to every photo without spots. A v2 build that meets a spot recipe preserves it (M-01 sidecar path, K-020 catalog demotion) instead of flushing the reduced copy.
   - The alternative was a global bump to 3. That would regenerate `canonical.json`/`default-recipe.json`, change every new recipe's `recipe_fp`, invalidate denoise artifact keys (`"p\(pipelineVersion)"`), and lock v2 builds out of every photo this build ever touches.
   - **Your call.**
3. **Missing keys in a spot fall back to constants.** A spot with no `sourceX`/`sourceY` falls back to 0.5/0.5 (the frame centre), not to its own destination. The codec tolerance rule forbids one field falling back to another. The destination fallback would have rendered as identity, which is nicer, but the rule won. Only a hand-made document can hit this.
4. **The Effects section no longer owns spots.** Before this, `develop.heal != Heal()` lit the Effects dot and the Effects Reset wrote `Heal()`. With spots real, resetting vignette and grain would have silently deleted all healing behind a panel with no spot controls. Now spots alone do not light the dot, and the Reset keeps them. The stroke fields behave as before. Spots are removed with ⌫ in the tool or with the whole-photo Reset.
5. **Choices made in the app (taste):**
   - The tool bar sits at the top centre of the loupe.
   - Size is shown as a diameter in source pixels, 2–400. docs/09 says "1–200 px (display)".
   - The default radius is 1% of the long edge.
   - Dragging a destination leaves the source where it is (LR's grammar).
   - A click places a spot. A drag over clear space does nothing, so a reach to pan does not litter the frame.
   - **While the tool is armed, the canvas takes every drag on the photograph, so panning by dragging is unavailable.** The scroll wheel still zooms and pans. This is how `MaskCanvas` behaves too.
6. **Spot edits target the primary photo only**, even with several selected. This follows the crop-Escape precedent.
7. **`/` (re-roll the source, docs/12) is not bound.** Adding it is a one-line `dispatchedKeys` change, plus calling `healAutoSource` with an exclusion of the current pick.

## FOUND-WHILE-FIXING / NOT DONE

- **Paste Settings copies `develop` wholesale**, so spots paste onto other frames, where they land on unrelated content. LR leaves Spot Removal unchecked in sync by default. This needs a decision on the paste-settings subset. Not changed here.
- **The auto-source search reads the S5 input without S3 denoise.** It runs on a window scaled so the spot radius is at most 24 px. The ranking is on texture at that scale, so denoise does not change it. This is stated in `healSearchBuffer`.
- **The GPU parity tolerance is 1e-3, not the masks' 1e-4.** Spots sample through Core Image's bilinear sampler, whose hardware weights have reduced sub-texel precision. The tolerance has not been measured on a Mac. If the lane shows the error is much smaller, tighten it.
- **Not built:** brushed heal strokes, Remove (ML), Dust Removal, per-pin source transform (flip, rotate, scale), cached raster artifacts (D52; spots are cheap enough to evaluate per frame), and an inverse geometry projection of the tool cursor at extreme rotations beyond what `MaskCanvas` already does.
- **The PatchMatch patent caution in docs/09 does not apply to what shipped.** The search is a deterministic ring search plus pattern search, not a randomized nearest-neighbour field, and the blend is Pérez.
- **The `GrainParityScanTests` header says "thirty-eight shader bodies"; there are now forty.** The comment belongs to another file and was left alone. The `Kernels.swift` header now says forty.
