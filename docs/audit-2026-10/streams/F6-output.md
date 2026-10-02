# F6-output: docs/11 against the export path

Stream agent F6-output. Branch `worktree-agent-a303794e531ff71ab`, based on
`claude/jolly-sagan-k7ch7z` (`cbf71e6`) and merged with trunk at the end. Build dir
`/tmp/lumen-build-f6`, Linux. LumenApp and LumenPipeline do not build here, so their changes are
**source-verified**: traced by hand, `scripts/check-swift-surface.py` exits 0, and the macOS tests
are written in the ImageIO readback style of `AuditExportMetadataTests`. The LumenCore halves run
here, and each was shown red under a mutation.

## Gap table (docs/11 vs code, verified at `cbf71e6`)

| Capability (docs/11) | Before | After | Where |
|---|---|---|---|
| Multi-recipe, one click | BUILT (no render sharing; docs/11 already says so) | unchanged | `AppStateActions.export` |
| Formats JPEG / HEIC / TIFF / PNG | BUILT | unchanged | `PipelineRenderer.write` |
| Bit depth 8/16 TIFF-PNG, 8/10 HEIC (probed) | BUILT | unchanged | `effectiveBitDepth`, `canWriteTenBitHEIC` |
| TIFF compression ZIP/LZW/none | MISSING (always uncompressed) | MISSING | needs a `CGImageDestination` TIFF path |
| JPEG 4:4:4 at q≥90 | MISSING/unverified (Core Image's choice) | unchanged | — |
| Colour spaces sRGB/P3/Adobe/2020/ProPhoto | BUILT | unchanged | `ExportColorSpace` |
| Custom ICC + intent + BPC | MISSING | MISSING | — |
| Hue-preserving gamut map into the destination | PARTIAL: only when the viewing proof (⇧S) is on (J3-03) | PARTIAL | `deliveredProof` |
| Resize none/long/short/W/H/MP, don't enlarge | BUILT | unchanged | `targetSize` |
| Resize % and W×H box | MISSING | MISSING | — |
| Output sharpening Screen/Matte/Glossy × L/S/H | PARTIAL: per-channel USM, not luminance (J3-06); no halo asymmetry | PARTIAL | `applyOutputSharpen` |
| Metadata: GPS/EXIF/serial/keywords/copyright/contact/DPI | BUILT (flags, not docs/11's 4 levels) | unchanged | `applyMetadataPolicy` |
| Lumen keywords written to IPTC (J3-04) | MISSING | MISSING | — |
| Watermark | BUILT (docs/11 still says deferred, K-103) | unchanged | `applyWatermark` |
| Filename tokens `{seq}` `{time}` `{camera}` `{lens}` `{iso}` `{rating}` `{label}` `{yyyy}{mm}{dd}`, sequence start | MISSING (4 tokens) | **BUILT** | `ExportNaming` |
| `{date}` = capture date (J3-05) | WRONG (file creation date) | **FIXED** | `ExportNaming`, `CaptureMetadataReader.captureWallClock` |
| Collapse warning before the run (J3-08) | MISSING | **BUILT** | sheet Naming section |
| `{job}` token, token destination paths, "subfolder of original" | MISSING | MISSING | — |
| Collision policy rename/overwrite/skip | PARTIAL (rename only) | **BUILT** | `ExportRecipe.placement` |
| Gain-map HDR export (HEIC, JPEG) | MISSING (`hdrIsWritable == false`) | **BUILT**, source-verified | `exportedHDRImage`, `write` |
| PQ HEIF / 16-bit TIFF absolute HDR; SDR trims; map resolution | MISSING | MISSING (mapScale stored, not applied) | — |
| Soft proof (viewing) + gain-map loupe preview | BUILT (F3 landed the EDR preview) | unchanged | — |
| Recipe-proofing (resize + sharpen), print-size zoom, delivery preview | MISSING | MISSING | — |
| After export: reveal / open with | MISSING | MISSING | — |
| Recipe sets, ⌥⌘⇧E export again, size estimate | MISSING | MISSING | — |
| Queue pause / reorder / persistence | PARTIAL (stop only) | unchanged | — |

## Items

| Item | Status | Commit | Red / green | Proof records that move |
|---|---|---|---|---|
| Naming grammar: capture-date `{date}` (J3-05), `{seq}` + sequence start + collapse warning (J3-08), docs/11's other tokens | FIXED | `559d785` | date priority reversed + `{seq}` removed: `ExportNamingTests` 6 failures in 10; restored 10/10. Old-renderer transcription identical over 14 templates × 3 sources × 3 recipe names | none |
| Collision policy rename / overwrite / skip | FIXED (renderer half source-verified) | `3c86b68` | always-rename substituted: 2 failures in 6; in-run guard removed: 2 failures; restored 6/6 | none |
| Gain-map HDR export (HEIC, JPEG, ISO 21496-1 via Core Image `hdrImage`) | FIXED, source-verified | `fcffd5a` | `hdrIsWritable` false + primary at HDR white + option removed: `ExportGainMapTests` 20 failures in 3 tests; restored 3/3. macOS readback written, not run here | none |

Merge of trunk: `6903b04` (brings F3's `EDRPreview`; my HDR rendition renders at
`HDRSettings.whiteTargetPercent`, the value `EDRPreview.whiteTarget` returns when the display covers
the content, so the loupe preview and the file's HDR side are one plan at one white).

## Byte identity

- Naming: every template the old grammar knew renders the same name, except `{date}`, which now
  reads the EXIF capture time first (file creation date, read the old way, is the fallback).
- Collision: default `.rename` is exactly the old `disambiguated` call.
- Gain map: a recipe without HDR settings gets the same SDR render and the same encoder options. A
  recipe with "Emit gain map" on keeps its primary pixels and gains a map.

## DECISIONS

1. **`{date}` meaning changed** (J3-05): a re-export of an existing `{date}` recipe names files
   after the capture day, not the copy day. This is the audit's fix. Owner can veto.
2. **`{seq}` is four digits**, the ingest renamer's spelling ("one grammar"). docs/11 reads as if
   `{seq}` were unpadded beside `{seq3}`/`{seq4}`. Both aliases also work.
3. **Collision default stays Rename**, not docs/11's (also Rename). Overwrite and Skip never apply to
   two frames of the same batch: those are always renamed.
4. **Gain map on for recipes that already had "Emit gain map" ticked.** The toggle was the opt-in;
   those files now carry a map. The stock "HDR HEIC" recipe is disabled by default.
5. **Map resolution** is Core Image's choice; `mapScale` is stored and shown as not applied.
6. **The sheet's new copy** ("If it exists" help, naming warnings, HDR note) is mine.

## Not done (remaining, in my priority order)

1. Destination gamut mapping as a per-recipe opt-in intent (J3-03): design in
   `ExportRecipe` as `renderingIntent: RenderingIntent?`, nil = today; `exportPlan` would take
   `SoftProof(enabled: true, space: colorSpace, intent:, warnings off)`. Needs the
   `SoftProofExportTests` pin on `softProof: Self.deliveredProof(softProof)` updated.
2. Resize by % and fit-within W×H (pure `targetSize` work, plus a second value field).
3. After-export reveal / open-with.
4. Opt-in Lumen keywords to IPTC (J3-04), `{job}` token.
5. TIFF LZW/ZIP via `CGImageDestination`, opt-in.
6. Luminance-only output sharpening (J3-06). It moves pixels for every sharpened recipe,
   including the stock web preset, so it needs an owner decision, not an opt-in.

## FOUND-WHILE-FIXING

- `check-swift-surface.py` reports a property passed as `source: source` / `source: nef` from a
  test class's `private let` as "not in scope". I worked around it with a `static let`. The
  checker has a false positive there.
- On a stopped batch, the "Stopped" branch compares `written` with `total`. Skipped files count
  as unwritten, so Stop pressed during the last file of a batch that had skips reads as stopped.
  The condition text is pinned exactly by `ExportCancelAdversarialTests.haltedBranchHead`, so I
  left it alone.
- **Needs a Mac:** `ExportDeliveryReadbackTests` (gain map present, HDR peak > 1.5, primary =
  plain export; overwrite replaces). The tolerance numbers are first guesses for the fixture.
