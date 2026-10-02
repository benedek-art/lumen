# Q6-lutcache: the preview key reflects whether the LUT is available

This is a follow-up to F2-lut's FOUND-WHILE-FIXING item. When a recipe's LUT blob is missing
on this machine, the picture renders without the LUT, but `recipe_fp` still hashes the LUT.
The developed preview was filed under that `recipe_fp`. When the blob later arrived (from a
backup restore or a sidecar from another catalog), the stale no-LUT picture went on being
served as the LUT picture.

| Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|
| Preview key reflects LUT availability | FIXED (LumenCore part tested on Linux; the two LumenApp call sites are source-verified) | see `git log` (this commit) | 3 failures in `testAPreviewRenderedWithoutAMissingLUTIsNotServedOnceTheLUTArrives` with the suffix removed; 17/17 `CreativeLUTTests` green with it restored | none |

## Mechanism

- `RecipeFingerprint.previewFingerprint(_:library:)` and `(recipeFingerprint:recipe:library:)`
  return `recipe_fp` with `+lut-missing` appended when the LUT is hashed (non-empty ref,
  Amount > 0) and `CreativeLUTStage` resolves to nil. In every other case they return
  `recipe_fp` unchanged, so no existing preview key moves.
- `CatalogStore.currentPreviewFingerprint(photoID:library:)` runs one query. It returns the
  recipe text only when that text contains `"lut"`, so an ordinary edit decodes no JSON on
  the grid path.
- Two LumenApp call sites changed. `CatalogService.previewFingerprint` now goes through the
  preview cache's lookup, filing and invalidation. `RenderCoordinator` now uses it for the
  `DevelopedPreviewIdentity` that a finished render is filed under. After the blob arrives,
  the key drops back to the plain `recipe_fp`. `decide` then refuses the stale fit/1:1 row and
  `invalidatePreviews(keeping:)` deletes it.
- `recipe_fp` itself does not change. Sidecar merge, edit history and the XMP fingerprint
  still compare what the recipe says.

## DECISIONS

None. Missing-blob recipes get a new key, and nothing else changes.

## FOUND-WHILE-FIXING

- The browse rungs (thumb and grid) serve a mismatched row as `.browsable` by design. After
  the blob arrives, a grid cell can keep showing the no-LUT thumbnail until it is
  re-rendered. Edits already behave this way.
- `CreativeLUTLibrary.cube(for:)` reads the blob store on every call for a missing ref.
  That is one failed file read per render or preview key while the blob stays missing.
