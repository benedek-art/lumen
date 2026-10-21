# WS-41 Vignette: hunks outside the lane's owned functions

Every hunk below is single-purpose: it carries the four new vignette fields (or the one
`VignetteSettings` value that bundles them) through code another lane owns. Nothing else
in those files was touched. Line numbers are on the WS-41 build commit.

## Stage chain and plan (WS-01)

| File:line | Hunk | Why |
|---|---|---|
| `Sources/LumenCore/Engine/RenderPlan.swift:126-128` | `public let vignette: VignetteSettings` in the carried-through fields | One value for both S13 call lines, so they change once (lead's decision). `vignetteEV`/`vignetteFeather` stay for existing readers. |
| `Sources/LumenCore/Engine/RenderPlan.swift:499` | `self.vignette = VignetteSettings(look: look)` in the `---- carried through` block | Same. |
| `Sources/LumenCore/Engine/ReferenceRenderer.swift:133-134` | `DetailEngine.vignette(image, plan.vignette, geometry: plan.recipe.develop.geometry)` | The reference now lays the vignette out on the crop (AUDIT F7, SPEC lines 22-23). The gate line `if plan.vignetteEV != 0` is unchanged. |
| `Sources/LumenPipeline/RenderGraph.swift:242-243` | `applyVignette(image, plan.vignette, geometry: plan.recipe.develop.geometry)` | Same call shape on the GPU. |

## Registries and recipe schema (WS-58)

| File:line | Hunk | Why |
|---|---|---|
| `Sources/LumenCore/Recipe/RecipeLook.swift` (fields after `vignetteFeather`, defaults, init params, `CodingKeys`, `init(from:)`) | `vignetteMidpoint`, `vignetteRoundness`, `vignetteHighlights`, `vignetteStyle`, copied from how `vignetteFeather` was added; absent keys decode to the defaults | SPEC "Recipe" clause and line 5. Owned as `Look.vignette*`, listed because the struct is a WS-58 hot spot. |
| `Sources/LumenCore/Recipe/SettingsSubset.swift:169-172` | four copy lines in `.effects` | SPEC line 28: Copy Settings carries the vignette whole. |
| `Sources/LumenCore/Recipe/LookSubset.swift:282-284` | `Num.mix` for midpoint, roundness, highlights | SPEC line 28; the style lands whole because `out` starts from `carried`. |
| `Sources/LumenCore/Interaction/WorkspaceModification.swift:145-148` | the four fields in `nonDefault`'s `.effects` clause | SPEC line 27: the Effects dot. |
| `Sources/LumenCore/Interaction/WorkspaceModification.swift:270-273` | the four fields in `WorkspaceSection.effects.reset` | SPEC line 27: the section Reset. |
| `Sources/LumenCore/Interaction/ControlIndex.swift:157-159` | aliases `midpoint`, `roundness`, `highlight priority`, `color priority`, `paint overlay` | SPEC line 28. |
| `Sources/LumenRender/RecipeKeys.swift:280-283` | ranges for the three numeric keys | SPEC line 28 (`lumen-render keys`). |
| `scripts/gen-fixtures.py:399-404` and `Tests/LumenCoreTests/Fixtures/default-recipe.json` | the four defaults in `DEFAULT_RECIPE`, fixture regenerated with the script | SPEC line 5(d); `gen-fixtures.py --check` passes. |

## New file

- `Sources/LumenCore/Image/VignetteGeometry.swift`: `VignetteStyle`, `VignetteSettings`, and `VignetteField`, the one coordinate field both renderers read. It is `PipelineRenderer.geometryRects` transcribed into Doubles. `geometryRects` itself (WS-25) is untouched; `VignetteStyleParityTests.testTheSharedFieldIsGeometryRects` (macOS) holds the two to 1e-9.

## Kernel registry

- No registry line changed. `lumenVignette` keeps its name and its slot in `KernelLibrary.vignette` and `unavailableKernels`; only its signature changed, from 12 to 21 arguments (`Kernels.swift`, owned).

## Tests outside the lane's own files

| File | Change | Why |
|---|---|---|
| `Tests/LumenCoreTests/RawDenoiseRecipeTests.swift:19` | `defaultFullTreeDigest` re-pinned | It hashes the FULL default tree, which gains the four keys (the same change as `default-recipe.json`). The sparse canonical form and every fingerprint in that file are unchanged and still asserted. |
| `Tests/LumenCoreTests/SettingsSubsetTests.swift` | `Look` field count 10 → 14 | Its own message says to update it when Look grows a field that has a group; all four are in `.effects`. |
| `Tests/LumenCoreTests/SavedLookTests.swift` | fixture sets the four fields off default (additions only) | Its own guard requires every Look field to be off default in the fixture. |
| `Tests/LumenCoreTests/RecipeCodecToleranceTests.swift`, `ResetSemanticsTests.swift` | the four fields added to the "everything off default" samples (additions only) | Named in the SPEC. |
| `Tests/LumenCoreTests/SliderEvidenceTests.swift` | three new contract rows, `look.vignetteStyle` in `notASlider`, the feather row pointed at its replacement test | Named in the SPEC. |
| `Tests/LumenAppTests/LayoutMetricSupport.swift` | four rows, the moved Effects citations re-numbered, `callSiteCount` 106 → 109 | Named in the SPEC. |
| `Tests/LumenAppTests/LayoutMetricTests.swift:528` | the proof-intent citation `EffectsPanel.swift:536` → `:578` | A printed citation that this lane's new rows moved. |
