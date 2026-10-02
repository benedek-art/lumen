# F2-lut — creative LUT stage

Feature stream. `look.lut` was stored, round-tripped and stripped from the render identity
because nothing read it (`docs/audit-2026-09/STATUS.md`: "a parser waiting on a render
STAGE, not a caller"). It is now a stage on both renderers, with storage, UI and tests.

| Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|
| Stage on the CPU reference, render identity, look blend, palette entry | FIXED | `0ba5900` | 13 failures with the identity strip restored, the display tap removed and the look blend removed; 2 more with the taps moved (display after grain, log after the transform) | none |
| Stage on the GPU graph + parity tests | FIXED (source-verified) | `e320abf` | macOS only; see the commit body | none |
| Looks-section UI (choose, Interpretation, Amount, remove) + app wiring | FIXED (source-verified) | `55d2f19` | SliderEvidence: 1 failure without the manifest rows; surface checker exit 0 | none |
| Trunk merge (heal stage, version split) | — | `10dbfb8` | CreativeLUTTests 16/16 after the merge | none |

## What was built

- **Recipe field**: the existing `look.lut` (`LUTReference`: `ref`, `name`, `tap`, `amount`).
  `ref` = `blob:xxh64:<16 hex>` of the `.cube` file's own bytes. `tap` is the declared
  input/output space: `.display` = sRGB-encoded, display-referred (IEC 61966-2-1, D65, [0,1]);
  `.log` = `LumenLog` over linear Rec.2020. Amount runs 0–100 and blends linearly against the stage input.
- **Storage**: `CreativeLUTImport.importCube` parses first, then `BlobStore.store` puts the
  bytes in the same `blobs/` directory as the brush strokes, so `BlobStore.backUp`/`restore`
  (the catalog backup) carry them with no change. `CreativeLUTLibrary.shared` parses each ref
  once; `CatalogService.init` attaches its blob store to it.
- **Stage** (`Sources/LumenCore/Engine/CreativeLUT.swift`): the cube is sampled at its own
  resolution and never re-baked into a second table.
  - display tap: S15, after the local-curve tap and before grain (docs/14 §2 lists S15 as
    "tone curve, local curve tap, display-interpreted LUTs"). It goes before grain because
    the export lays grain down after its resize, so this is the only position that preview
    and export share.
  - log tap: the last scene-referred stage, after S13 vignette/halation, before S14.
  - GPU (`RenderGraph.applyCreativeLUT`): the same steps using a matrix, `CIColorClamp`,
    `CILinearToSRGBToneCurve`, `CIColorCube`, `CISRGBToneCurveToLinear`, a matrix, and the
    existing `blendMask` for Amount. There is no new kernel, and ColorEngine and the plan
    tables are untouched (stream P5's territory).
- **Render identity**: the LUT is now hashed. It is still stripped when Amount ≤ 0 or the
  ref is empty, since neither renders. The name is blanked because it is a label.
- **Saved looks**: `LookSubset.blendedLUT`. A look applied at partial Amount dials the LUT's
  Amount; the cube itself is categorical and is not blended.
- **UI**: a "Creative LUT" header in Looks, between Saved Looks and Display Transform. The
  header's verb chooses a `.cube`. The rows are the LUT's name with Remove, a Display/Log
  segmented control and Amount. Header Reset removes the LUT. Only existing tokens are used.
  `ControlIndex` gets `look.lut` back, and the "lut"/"cube" aliases move off Film Lab.

## No-LUT byte identity

When `CreativeLUTStage(reference:)` returns nil, both renderers skip both taps outright.
That covers no LUT, an empty ref, Amount ≤ 0, and a blob that is missing on this machine.
The code a no-LUT recipe runs is therefore the code it ran before.

- `testEveryInertLUTRendersExactlyTheNoLUTPicture` pins each nil case byte for byte.
- `CreativeLUTParityTests.testAnInertLUTLeavesTheGraphBitIdentical` does the same on the GPU.
- No `ProofRegistry` spec sets `look.lut`. `ProofSmokeTests` passed.
- The full `ControlProofTests` drift run did not finish within the 1-hour background limit
  on the shared box (its class `setUp` measures all 135 records). It was stopped, not
  failed. The orchestrator's CI lane should confirm it. **Proof records that move: none.**

## Newer-build guard (M-01)

LUTReference's four wire keys are version-2 vocabulary, so any older build round-trips a LUT
recipe intact. `testTheLUTWireKeysAreTheOnesEveryVersion2BuildDecodes` pins the key set; a
fifth key needs a stated-version bump. A LUT raises no stated version (pinned), and
`XMPSidecar.writableFields` still refuses documents newer than `supportedPipelineVersion`.

## Tests

- Linux, `CreativeLUTTests` (16 tests): parse and apply at both taps, Amount, position (display
  on the formed picture, display before grain, log before the transform), the inert cases,
  render identity, round-trips (recipe JSON, XMP sidecar, saved look), the partial look
  blend, the key pin, the version guard, import and storage, and rejection without storing.
- `CanonicalJSONTests`: the old LUT tripwire is inverted.
- GPU parity, macOS, `CreativeLUTParityTests`: an affine 2³ cube (bound 0.05 sRGB code), a
  curved 17³ cube (bound 1 code, the trilinear vs tetrahedral gap), the log tap (0.5), and
  inert bit-identity.
- `UnwiredEngineTests` (macOS): its two LUT tests are inverted, as their own messages asked.

## DECISIONS

1. **No stated-version raise for LUT recipes.** No data is lost, because older builds keep
   the key, but an older build renders such a recipe without its LUT. The other option is
   the heal stream's `statedVersion` mechanism, which makes older builds refuse to write the
   recipe. That would protect D52's "rendering gates on version" at the cost of write access.
   The owner should choose.
2. **Display tap clamps at SDR white.** An HDR rendition loses its headroom wherever a
   display LUT is at full Amount. That follows the spec ("SDR-referred"), but the HDR gain map
   flattens. The alternative is passing headroom through above 1.
3. **Display tap sits after the local curve and before grain.** The gamut-warning flag colour
   also passes through the LUT. This keeps CPU/GPU parity; the alternative is a separate
   pass after the LUT.
4. **No gamut soft-clip after the LUT.** Docs/05 says LUT output passes through the always-on
   soft-clip. The display tap's output is sRGB [0,1]-bounded by construction. The log tap has
   none; adding one would mean touching the colour/gamut plumbing that P5 owns.
5. **UI placement and shape.** The LUT is rows in the Looks section, not docs/05's
   "preset card next to the film stocks", and there is no drag-and-drop. The import defaults
   are Display and 100.
6. **No proof-registry sweep for `look.lut.amount`.** It is pinned as a contract instead.
   Adding a record would need a cube fixture and a new record; existing records are unaffected.

## FOUND-WHILE-FIXING

- **A missing blob renders without the LUT, yet `recipe_fp` includes it.** If the blob
  arrives later (backup restore, sidecar from another machine), cached previews keyed on that
  fp are stale.
- **LUT bytes do not ride in the XMP sidecar** the way brush strokes do (`BrushStrokeSidecar`).
  A sidecar moved alone to another catalog carries the ref but not the cube.
- **`CIColorCube` interpolates trilinearly, while `LUT3D.sample` is tetrahedral.** This is the
  same gap every plan table has (AI-03). A tetrahedral CI kernel would close it for all of them.
