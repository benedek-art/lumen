# Lumen Denoise inside Lumen: integration design

Status: design plus the first Swift slice (LumenCore maths, recipe field, macOS Core ML runner and pre-pass). The flag `RawDenoiseFeature.isEnabled` (`LUMEN_RAW_DENOISE=1`) is defined but not yet consulted anywhere, so no app code path reaches the new code yet. `RawCFAProvider` has no conformer, and `DenoisedRawSource`, the DNG patcher and the UI are follow-ups. Nothing here changes Lumen's colour or tone maths.

Paths are repo-relative. Line numbers are from branch `claude/denoise-integration` at `04cc1d2` and will drift.

## 0. Summary

- Lumen never sees the CFA. Every RAW decodes through `CIRAWFilter`, and the only pixels Lumen gets are already demosaiced (section 1).
- The raw-domain model therefore runs as a **cached background pre-pass**. The pre-pass (`RawDenoisePrepass`, which exists) produces full-strength denoised CFA planes and caches them; a DNG patcher (follow-up) writes them into a denoised DNG, and a wrapper `ImageSource` hands that DNG to `CIRAWFilter` in place of the original file (option A). Everything downstream, including WB, colour, tone, masks and export, is unchanged.
- **Strength is not in the cache key.** The pre-pass stores the full-strength result, and strength is a linear blend applied at decode time, so the slider stays instant.
- Stage 1 depends on Adobe DNG Converter, which this photographer already has (`Denoise/lumen_denoise/dng.py`). Removing that dependency is stages 2 and 3, via a native DNG/LJ92 reader and then vendored LibRaw.

## 1. Where CFA data exists in Lumen today

There is no point in LumenCore or LumenPipeline where mosaiced data is available.

| Fact | Citation |
|---|---|
| RAW decoder is `CIRAWFilter`, held per source | `Sources/LumenPipeline/AppleRawSource.swift:31`, built with `CIRAWFilter(imageURL:)` at `:70` |
| Code states the decode is post-demosaic: "Apple's API does not expose the mosaic" | `Sources/LumenPipeline/AppleRawSource.swift:52-55` |
| The only pixels read are `filter.outputImage`, which is demosaiced, matrixed, extended-linear Rec.2020 | `Sources/LumenPipeline/AppleRawSource.swift:357` |
| "no CFA reader and no LibRaw" | `Sources/LumenCore/Image/RawTruth.swift:11` |
| The LibRaw `LumenRawSource` escape hatch and its "raw-domain ML splice point" (stage 7) exist only on paper | `docs/13-architecture.md` section 6, `docs/14-pipeline.md` section 4.3 |
| `RawParams.decoder` (`"apple"` or `"lumen"`) is stored and hashed but not acted on | `Sources/LumenCore/Recipe/Recipe.swift:474` |
| Exactly two `ImageSource` conformers, chosen by extension at one construction site | `Sources/LumenApp/RenderCoordinator.swift:932-934` (`RenderedImageSource` or `AppleRawSource`) |
| `ImageSource` protocol: `url`, sizes, as-shot neutral, metadata, provenance, `decode(recipe:draft:scaleFactor:) -> CIImage?` | `Sources/LumenPipeline/ImageSource.swift:28-50` |
| `linearSpaceFilter`, `isHighlightRecoveryEnabled` and the ProRAW matte properties are never set | grep of `Sources/` finds no match |

What the decode sets on a cache miss (`AppleRawSource.swift:299-357`) matters for the swap:
- WB is always as-shot (`:304-305`). Lumen's own WB is applied later, so **the CFA the model sees does not depend on any recipe WB setting.**
- Apple NR comes from `Denoise.appleStandIn` (`:351-353`, `Sources/LumenCore/Recipe/Recipe.swift:1286-1297`). It is (0, 0) for off and classic. For `.ai` it is (0.6 t, t).
- Sharpness, lens profile and decoder version are also recipe-driven (`:299`, `:336-337`, `:355`).

The decode cache key `DecodeKey` (`AppleRawSource.swift:131-142`) lives inside each source and has no URL field. A second `AppleRawSource` opened on a different file therefore gets its own independent cache. Option A relies on this.

## 2. Integration options

### A. Cached pre-pass producing a denoised CFA, re-wrapped as a DNG for CIRAWFilter (recommended)

Pipeline (stage 1):
1. **Get the CFA.** Run `Adobe DNG Converter -c -u -p0 -d <tmp> <src>`, which gives an uncompressed DNG (same flags as `dng.py`). A pure-Swift DNG reader in LumenCore parses the raw IFD (photometric 32803), BlackLevel and BlackLevelRepeatDim, WhiteLevel, CFAPattern, ActiveArea and DefaultCrop. It rejects compressed data, LinearizationTable, BlackLevelDeltaH/V and anything that is not 16 bits per sample.
2. **Normalize and pack.** Use `RawDenoisePacking.normalize`, `pack` and the RGGB reorder, all matching `raw.py::load`, `raw.pack` and `prepare.to_rggb`. The pattern comes from the DNG's CFAPattern, relative to the ActiveArea origin. Do not assume LibRaw's phase: Adobe's raw area can be offset from LibRaw's by a few pixels (`dng.py::_find_offset`).
3. **Noise parameters.** Look up `RawDenoiseNoiseTable.params(model:iso:)` with the EXIF Model and ISO (`CaptureMetadataReader`, `AppleRawSource.swift:94`). An unknown camera is unsupported in stage 1, because `noise.estimate` is not ported.
4. **Run the model.** `RawDenoiseTiler.run`, with the body computing `RawDenoiseStdMap.compute` on the padded tile and calling `RawDenoiseCoreMLRunner`. Store the result at **full strength**.
5. **Write back.** `unpack` and the RGGB inverse, then de-normalize with `clip(round(x * scale + black), 0, white)` as in `infer.py::denoise_file`. Patch the CFA bytes in place in the uncompressed DNG copy and write a new `RawDataUniqueID` if present. Then run `-c -p0` once more to recompress losslessly and recompute the digests, as `dng.py` step 7 does.
6. **Swap.** Store the file in the cache (section 4). `DenoisedRawSource` decodes it through an ordinary `AppleRawSource`.

Reading Adobe's own raw data removes `dng.py`'s alignment search and its defect-pixel special case. Pixels Adobe repaired are simply part of the input.

Trade-offs:
- Pro: no change to Lumen's colour or tone code, decode stage or graph. Export, HDR and probes follow automatically, because all of them go through `source.decode` (section 4.6).
- Pro: the model runs in exactly its training domain (raw DN, LibRaw-equivalent normalization).
- Pro: the output is a real DNG that Lightroom can open, which is the same artifact the standalone app makes.
- Con: needs Adobe DNG Converter at runtime. Each photo needs two converter runs, about 1-2 s each.
- Con: disk use is about one compressed DNG (roughly 40-60 MB for 33 MP) per cached photo.
- Con: **colour can shift between toggled-off and toggled-on.** The substitute is rendered from Adobe's ColorMatrix/ForwardMatrix and AsShotNeutral rather than Apple's built-in ARW/RW2 profile, and lens opcodes and crop can differ too. This is measured by parity gate P5 (section 6). If the gate fails, the "original" side of the blend switches to the *unmodified* converted DNG whenever the toggle is on, so strength 0 and 100 share one colour pipeline.
- Con: Apple's demosaic is not strictly linear, so blending after decode (section 4.3) differs slightly from `infer.py`'s CFA-domain blend at strengths between 0 and 1. Strengths 0 and 1 are exact.

Variant A2 is in-memory: `CIRAWFilter(imageData:identifierHint:)` on DNG bytes. It saves a disk write but holds about 70 MB per photo in RAM and does not survive relaunch. Use it only for one-off export if needed.

Variant A3 is CVPixelBuffer: `CIRAWFilter(cvPixelBuffer:properties:)` with a `kCVPixelFormatType_14Bayer_*` buffer. This would skip DNG writing and the second converter run. What `properties` it needs for correct colour from a file-sourced Bayer buffer is undocumented. Prototype it on the Mac in stage 2. It solves the output side only.

### B. Lumen-native CFA access

- **B1, own DNG reader** (needed for A anyway). Stage 1 handles uncompressed data only. Stage 2 adds a lossless JPEG (compression 7, LJ92) decoder of roughly 300-500 lines in LumenCore, Linux-testable. Native DNGs and the converter's default output can then be read without `-u`.
- **B2, vendored LibRaw** (CDDL-1.0, as chosen in `docs/14-pipeline.md` section 4.3) through a SwiftPM C target.
  - Reads ARW/RW2 directly and returns the same `raw_image_visible` and black/white levels the model was trained on, so it gives the best parity.
  - Costs: about 1 MB of C, a parser for untrusted files inside the app process, and ongoing upkeep.
  - It also unlocks Lumen's own demosaic (the docs/14 plan). That is a separate, much larger project.
- **B3, own ARW and RW2 decoders.** Sony lossless-compressed ARW and Panasonic RW2 compression are both proprietary and change between bodies. This is not worth it next to B2.

B removes the input-side converter dependency. It does not by itself solve output, which still needs a DNG for `CIRAWFilter` (A), a CVPixelBuffer (A3), or Lumen's own demosaic.

### C. Demosaiced-domain model on CIRAWFilter linear output

- The model would run on the RGB decode before Tier 1. That is the docs/07 "Tier 2 splice" at `RenderGraph.colorStageInput` (`Sources/LumenPipeline/RenderGraph.swift:179-192`, before `applyDenoise` at `:192`), and `AIDenoiseSplice.blend` (`Sources/LumenCore/Image/DenoiseEngine.swift:1409`) already exists.
- **It needs a new model and retraining.** Inputs would be 3-channel demosaiced RGB, and the noise model would no longer be per-pixel Poisson-Gaussian in DN: demosaic and the colour matrix correlate it spatially and across channels. The calibrated K and read_var tables no longer apply directly.
- It throws away the raw-domain advantage that is the reason this project exists. Demosaic has already turned noise into colour mazing.
- The existing `AIDenoiseSplice.TilePlan` (768/32, halo crop, `DenoiseEngine.swift:1618-1619`) is a different stitch from `infer.py` (1024/64, feathered), so it cannot be reused for parity.
- **Verdict:** keep it as a possible future second model, for example for rendered files. It is not the path for this denoiser.

### D. Inside the CIRAWFilter pipeline

- `CIRAWFilter` has no hook before demosaic. `linearSpaceFilter` is the only injection slot, and it receives demosaiced linear RGB, so it inherits all of C's problems.
- It also has more of its own. Apple evaluates it lazily per region and per `scaleFactor`, so a 1024-tile network with a receptive field would have to sit inside a `CIImageProcessorKernel`. It would run again on every decode-cache miss, and its output would differ between preview, settle and export scales.
- **Verdict:** rejected. The only workable "inside CIRAWFilter" route is A3, which hands `CIRAWFilter` a denoised Bayer buffer.

### Recommendation and staged plan

| Stage | Scope | Removes |
|---|---|---|
| 1 (this PR plus the next Mac session) | A with the Adobe converter: Swift maths in LumenCore, Core ML runner and pre-pass, recipe field, flag. Then the DNG reader/patcher, `DenoisedRawSource`, and cache wiring in LumenApp. | Python at runtime |
| 2 | B1 LJ92 reader so native DNGs need no first converter run. Port `noise.estimate` for unknown cameras. Prototype A3. | one converter run, the camera allow-list |
| 3 | B2 LibRaw `LumenRawSource` input. Output via A3, or Lumen's own minimal DNG writer (as in `dng.py::write_cfa_dng_scratch`, but carrying ForwardMatrix and opcodes). | Adobe DNG Converter |

## 3. Shared Swift API contract and what this PR implements

All names are binding. Implementers code against exactly this.

### LumenCore (`Sources/LumenCore/Image/RawDenoise/`, pure Swift, Linux-tested)

| File | API | Python reference |
|---|---|---|
| `RawDenoiseNoiseTable.swift` | `RawDenoiseNoiseTable` (`ISOSample {iso, k, readVar}`, `cameras` sorted by ISO, `init(jsonData:)` for the `calib.json` format, `isoRange(model:)`, `params(model:iso:)`). `RawDenoiseNoiseParams {k, readVar}` | `train.py::NoiseTable`, `infer.py::Engine.noise_params`. The ISO is clamped to the table range, then `exp(np.interp(log iso, log ISOs, log v))` in Double. |
| `RawDenoiseStdMap.swift` | `RawDenoiseStdMap.compute(packed:width:height:params:) -> [Float]` | `train.py::std_map`: mean of 4 channels, clamped at 0 or above, 3x3 mean with zero padding always divided by 9, then `sqrt(K*sig + r)` |
| `RawDenoiseTiling.swift` | `RawDenoiseTilePlan(width:height:tile:overlap:)` with `tiles` (`y0, x0, height, width, padBottom, padRight`). `RawDenoiseTiler.featherWeights`, `reflectPad`, `run(packed:width:height:tile:overlap:body:)`, `blend(denoised:original:strength:)` | `infer.py::Engine.denoise_packed`, `np.pad(mode="reflect")`, `d = s*d + (1-s)*p` |
| `RawDenoisePacking.swift` | `CFAPattern {rggb, bggr, grbg, gbrg}`. `RawDenoisePacking.pack`, `unpack`, `normalize` | `raw.pack`, `raw.unpack`, `prepare.to_rggb` and `from_rggb`, `raw.load` normalization |
| `RawDenoiseCache.swift` | `RawDenoiseCacheKey {sourceIdentity, modelID, calibDigest, k, readVar}` with `stableString` and `digest`. `RawDenoiseFeature.isEnabled` | none |

### Recipe (`Sources/LumenCore/Recipe/Recipe.swift`, `struct Denoise`)

- `public var raw: RawDenoiseSettings?` (`recipe.develop.denoise.raw`; do not confuse it with `develop.raw: RawParams`).
- `RawDenoiseSettings {enabled = false, strength = 100 (0...100), model: String?}`, decoded tolerantly. See section 5.

### LumenPipeline (macOS, `#if os(macOS) && canImport(CoreML)`)

- `Sources/LumenPipeline/RawDenoiseCoreMLRunner.swift`: loads the model from an explicit URL (`init(modelURL:computeUnits:compiledCacheDirectory:)`, compute units default `.all`; it does not search for the model) and runs one padded tile. It reads `com.lumen.denoise.model_id` and `com.lumen.denoise.calib_digest` from the model's `MLModelDescription.metadata[.creatorDefinedKey]` (written by `Denoise/scripts/export_coreml.py`) for the cache key (section 4.1). I/O is `noisy` (1,4,H,W) and `std` (1,1,H,W) in, `denoised` (1,4,H,W) out, Float16, with H and W multiples of 16 and flexible shape. The model includes `Denoiser.forward`'s residual scale, `s = mean(std)` over the padded tile, clamped at 1e-5 or above.
- `Sources/LumenPipeline/RawDenoisePrepass.swift`: actor `RawDenoisePrepass`. Source URL plus `RawDenoiseCacheKey` in, full-strength denoised packed planes (`RawDenoisePlanes`) out. Input comes from a `RawCFAProvider`, a protocol with no conformer yet. It ties tiler, std map and runner together, reports progress per tile, joins a second request for a key already in flight, and cancels between tiles once nobody waits. Results are cached in two tiers keyed by `key.digest`: an in-memory LRU (default 512 MiB, about four A7 IV frames as Float32) and `.lrdn` files on disk (Float16 by default). See section 4.5.

Tests are in `Tests/LumenCoreTests/RawDenoise*Tests.swift`, with golden fixtures generated from the real `Denoise/lumen_denoise` functions (or a faithful numpy port where torch is absent, as noted in the PR). There is also recipe round-trip and tolerance coverage (`RecipeCodecToleranceTests` picks up the new type through `populated()`).

**Not in this PR**, to be done next on the Mac or in a follow-up:
- a `RawCFAProvider` conformer (the DNG raw-IFD reader of section 2, step 1);
- the DNG patcher that writes cached planes back into a converted DNG (the swap DNG, section 4.5);
- `DenoisedRawSource` and the swap at `RenderCoordinator.swift:932-934`;
- consulting `RawDenoiseFeature.isEnabled` anywhere, and the `Denoise.appleStandIn` change for the pending state (section 4.2);
- indexing the swap DNG in `cache.artifact`, and deleting payload files when rows are deleted (section 4.5);
- panel UI;
- the preview-fingerprint suffix.

## 4. Background pre-pass and cache

### 4.1 Key

`RawDenoiseCacheKey` holds:
- `sourceIdentity`: the catalog's confirmed content fingerprint, the photo's quick signature (`photo.quick_sig`, the value `CatalogStore.scan` and `validateOriginalRelink` confirm a file against). `SourceFileIdentity` (`Sources/LumenCore/Catalog/SourceFileIdentity.swift:22`) is a stat token, not a content digest. A changed token is only a trigger to re-verify the quick signature; the key changes only when the confirmed signature does. Never put the token itself in the key: a metadata touch or a re-plugged drive would orphan every entry. Do not switch to `photo.full_hash` once it is computed either, because that would orphan existing entries the same way.
- `modelID`: `"<model_id>/t<tile>o<overlap>"`, for example `0123456789abcdef/t1024o64`. `model_id` is the first 16 hex of the sha256 of the `.pt` weights, written by `Denoise/scripts/export_coreml.py` into `lumen_denoise.coreml.json` and into the package metadata key `com.lumen.denoise.model_id`, which the runner reads. Tile and overlap change the stitch and have no fields of their own, so they belong in this string. Output-format versions are not in it: the `.lrdn` header carries its own version and is refused on mismatch, and the swap DNG's version is the `cache.artifact` row's `pipelineVersion`.
- `calibDigest`: the full sha256 hex of the `calib.json` bytes, as exported in `com.lumen.denoise.calib_digest`. The host hashes the `calib.json` it loads into `RawDenoiseNoiseTable` and refuses it if the digest differs from the model's.
- `k` and `readVar`: the resolved parameters after ISO clamping. Two ISOs that clamp to the same parameters share an entry.

Deliberately **excluded**:
- strength (blended at use, section 4.3);
- WB, temp and tint (the CFA does not depend on them, which is why `RecipeFingerprint.denoiseInputFingerprint`, `Sources/LumenCore/Recipe/Fingerprint.swift:174-181`, is the wrong key here);
- every look, tone, mask and geometry setting;
- decoder version, which applies when the substitute DNG is decoded, not to the pre-pass.

### 4.2 Draft and full

- **There is no network draft.** The model is raw-domain, so a reduced-resolution pass would need a different noise parameterization, and its output could not be swapped in as a full-geometry DNG.
- **Full pass:** one pass at native resolution, about 12 tiles of 1024x1024 for a 33 MP A7 IV. The target is 10 s or less per photo including the converter runs; Python is 6.2 s end to end today (`Denoise/docs/STATUS.md`).
- **While pending:** when `raw.enabled` is true and the artifact is missing, rendering uses the Apple NR stand-in, and the panel shows "AI denoise: computing NN%". This matches docs/07's "stale artifact falls back with a badge". The stand-in must follow the raw slider: when `raw.enabled` is true, `Denoise.appleStandIn` returns `(0.6 f, f)` with `f = raw.strengthFraction`, in place of `amount / 100`. Today it reads only `mode` and `amount` (`Sources/LumenCore/Recipe/Recipe.swift`, `appleStandIn`), so this is a follow-up change there. At strength 0 the stand-in is therefore (0, 0), Apple NR off.

### 4.3 Swap and instant strength

`DenoisedRawSource: ImageSource` is created at `RenderCoordinator.swift:932-934` when the flag is on and the file is RAW.
- `url` is the **original** URL. Mattes (`PipelineRenderer.swift:562, 920`), plan tables (`:303`), mask raster keys (`:2043-2052`) and band hues (`:249-271`) therefore stay keyed to the photo.
- It holds `original: AppleRawSource` and `denoised: AppleRawSource?` (opened on the cached DNG once ready).

How `decode(recipe:draft:scaleFactor:)` behaves:
- **Raw denoise off:** `original.decode(recipe, ...)` exactly as today.
- **Artifact missing (pending):** `original.decode(recipe, ...)`, with the stand-in following `raw.strengthFraction` (section 4.2).
- **Ready, strength 0:** `original.decode(r0, ...)` (`r0` below), the original with Apple NR off. That is the same image the pending path gives at strength 0, so strength 0 does not change when the artifact lands.
- **Ready, strength 100:** `denoised.decode(r0, ...)`, where `r0` is the recipe with `develop.denoise.mode = .off`. That makes `appleStandIn` return (0, 0), so Apple NR never stacks on the network. Tier 1 is unaffected, because `RenderPlan` reads the real recipe and not the decode recipe.
- **Ready, strength 0 < s < 100:** decode both with `r0`, then `s*denoised + (1-s)*original` with a `CIColorMatrix` scale on each and a `CIAdditionCompositing`. Both images are in the same extended-linear working space and extent. Dragging strength never re-runs the network or re-decodes: each source's `DecodeKey` is unchanged, so both decodes hit their caches.
- **Geometry guard:** if `denoised.nativePixelSize != original.nativePixelSize`, refuse the swap and keep showing the original with an error badge. Masks, spots and crops are stored in original-image coordinates.

Residency:
- A blend at s < 100 holds two decodes.
- `RenderCoordinator.trimDecodeResidency` downcasts `as? AppleRawSource` (`RenderCoordinator.swift:192, 198`). It must switch to a small protocol (`heldDecodeBytes`, `releaseDecodes()`) that the wrapper also implements, or the wrapper's bytes are invisible to the budget.

When the artifact lands:
1. The pre-pass actor reports to `RenderCoordinator`, which opens `denoised` on the wrapper and releases the wrapper's decodes.
2. Drop that URL's mask rasters and band hues, because luminance and colour range masks were measured on noisy pixels.
3. Re-render.
4. Do **not** call `invalidate(url:)` (`RenderCoordinator.swift:716`). It forgets mattes, and the subject geometry has not changed.

Preview cache:
- `RecipeFingerprint.previewFingerprint` gets a `+rawdenoise-pending` suffix when raw denoise is enabled and the artifact is missing, following the `lutMissingSuffix` precedent (`Fingerprint.swift:131-162`).
- A fallback frame is then never filed under the final key, and `recipe_fp` itself stays machine-independent.

### 4.4 Scheduling

- **`RawDenoisePrepass` runs on its own actor, never on `RenderCoordinator`.** That actor is serial and a decode cannot be cancelled (`RenderCoordinator.swift:677-682`).
- **One job at a time.** Priority order: the photo in the viewer, then export, then filmstrip neighbours, then background batch. Toggling off cancels a queued job, and cancels a running one between tiles.
- **Compute units:** `.all` (the runner's default) for the default RangeDim export, which Core ML commonly places on the GPU; `.cpuAndGPU` if `ALL` fails parity. `.cpuAndNeuralEngine` only with an `--enumerated` export (`Denoise/docs/COREML_EXPORT.md`, troubleshooting), and only after the Core ML performance report or `MLComputePlan` shows the convolutions placed on the ANE and parity passes with `CPU_AND_NE`.
- **Progress:** fixed weights per phase: convert 10%, read and pack 5%, tiles 70% (per tile), write 5%, recompress 10%. The fraction is published to the panel and the export sheet.

### 4.5 Storage, invalidation, budget

There are two cached artifacts. Only the first exists today.

**Planes tier (exists, `RawDenoisePrepass`).**
- Memory: an LRU of full-strength `RawDenoisePlanes` (Float32) under `Configuration.memoryBudgetBytes`, default 512 MiB. A frame larger than the whole budget is served from disk instead of evicting everything.
- Disk: when `Configuration.cacheDirectory` is set, one file per key at `<cacheDirectory>/<digest[0:2]>/<digest>.lrdn`. It has a 96-byte header (magic `LRDNCFA1`, format version 1, encoding, shape, the key digest) and then the planes, Float16 by default (`.float32` for parity runs), about 66 MB for a 33 MP frame. A file that does not parse exactly, or names another digest, is deleted and recomputed. Writes are atomic.
- Budget: `Configuration.diskBudgetBytes`; after each write the least recently read `.lrdn` files are deleted down to it. `nil` (the default) is unbounded, so the host must set it. `purge(includingDisk:)` drops the memory tier and optionally the whole directory.
- The `.lrdn` files are not in the catalog. Deleting a photo leaves its file until the disk budget evicts it, which is harmless because the key names content, not a photo.

**Swap-DNG tier (follow-up, needs the DNG patcher).**
- The patcher writes the cached planes into the converted DNG (section 2, step 5). The result is stored at `<catalog>/artifacts/<digest[0:2]>/<digest>.dng`, using the `AIDenoiseSplice.ArtifactKey.relativePath` sharding (`DenoiseEngine.swift:1515-1534`). It is indexed in `cache.artifact` with kind `"denoise-cfa"`, `modelID`, `prefixHash = key.digest` and `pipelineVersion`, via `CatalogStore.recordArtifact` and `artifact(...)` (`Sources/LumenCore/Catalog/CatalogStore.swift:4055, 4096`).
- Budget: 8 GiB by default, about 150 compressed 33 MP DNGs. `pruneArtifacts(kind: "denoise-cfa", maxBytes:)` (`:4130`) runs after each write, and `touchArtifact` (`:4112`) runs on each swap. Temporary converter output is written under the pre-pass's own temp directory and deleted on success and on failure.
- **Deletion only removes rows today.** `deletePhoto` (`CatalogStore.swift:2168`), relink (`:2282`), the scan's replaced-file path (`:2435`), `pruneArtifacts` (`:4146`) and `discardArtifact` (`:4161`) all `DELETE FROM cache.artifact` and never touch the file. Every caller must delete the payload file for each row it removes: `pruneArtifacts` returns the victim rows for this, and photo deletion and relink must read the photo's artifact rows first. Without that the 8 GiB budget is enforced on rows while the DNGs stay on disk.

**Invalidation is by key only** in both tiers. A new confirmed source signature, model weights, `calib.json`, tile/overlap or noise parameters gives a new key, and the old entry ages out. Toggling off, changing strength and editing anything else keep it.

### 4.6 Export

Every export path decodes through `source.decode` at scale 1.0 (`PipelineRenderer.swift:909` delivered rendition, `:1132` HDR pair), so the swap applies to export automatically.

If an exported photo has `raw.enabled` true and no artifact:
1. Export enqueues the pre-pass at export priority and waits, showing progress in the export sheet.
2. It never silently exports the stand-in.
3. If the pre-pass fails (no converter, unsupported camera or pattern, model missing, parity guard), that photo's export fails with the reason. The sheet offers "Export without AI denoise", which exports the current Tier 1 or stand-in rendering.

## 5. Recipe field and feature flag

Recipe:
- `develop.denoise.raw: RawDenoiseSettings?` defaults to nil, and a nil value is omitted from encoding. Existing canonical JSON, `recipe_fp`, `Tests/LumenCoreTests/Fixtures/canonical.json` and `default-recipe.json` stay byte-identical, and `scripts/gen-fixtures.py` needs no change. Canonical JSON is sparse against the defaults (`Sources/LumenCore/Recipe/CanonicalJSON.swift:120-152`).
- Decoding is tolerant: every key uses `decodeIfPresent ?? default`, and strength is clamped to 0...100 and made finite, so `{}` decodes to the defaults (`RecipeCodecToleranceTests`).
- **No new `Denoise.Mode` case**, because older builds fail on unknown enum cases (`Sources/LumenCore/Recipe/RecipeDecoding.swift:34-37`).

Fingerprinting:
- `renderIdentity` should map `raw` with `enabled == false` to nil, the same way it strips a disabled B&W (`Recipe.swift:261`), so switching it off does not split caches.
- It must **not** strip on the feature flag. `recipe_fp` is shared through sidecars and the catalog and must not depend on a local environment variable. With the flag off, the field round-trips untouched and rendering ignores it.

Panel (later, LumenApp):
- With the flag on, the existing AI segment (`Sources/LumenApp/DetailPanel.swift:503-516, 657-690`) writes `mode = .ai` and `raw.enabled = true`, and binds its slider to `raw.strength`.
- In `.ai` mode, Tier 1's coupling already zeroes luma and chroma unless the user set them (`Sources/LumenCore/Image/DenoiseEngine.swift:1884-1908`), so the frame is not denoised twice.

Flag:
- `RawDenoiseFeature.isEnabled` is true when `LUMEN_RAW_DENOISE=1` is set in the environment, and tests can override it. Nothing consults it yet; the source construction site and the panel must (section 7, step 4).
- LumenApp may later also read a UserDefaults key (`rawDenoise.enabled`), following the `cullingAssistsEnabled` precedent (`Sources/LumenApp/AppState.swift:2186-2191`).
- With the flag off, no source wrapper is created, no pre-pass runs, and every path is today's code.

## 6. Parity plan

The references are the real Python functions. Fixtures are float32 little-endian `.bin` plus a JSON header, or JSON for small cases.

| Gate | Compare | Tolerance | Where |
|---|---|---|---|
| P1 noise table | Swift `params` vs `NoiseTable.params` with `noise_params` clamping, both cameras, in-table, between-row and out-of-range ISOs | relative 1e-12 | Linux, `RawDenoiseNoiseTableTests` |
| P2 std map | Swift fp32 vs `train.py::std_map` in **fp32** on CPU, including borders and negative inputs | absolute 1e-7 or relative 1e-5 | Linux |
| P3 tiling | tile list vs `denoise_packed` loop for small sizes (below 16, below tile, exact, odd, and 3516x2344 giving 12 tiles); `run` with an identity body returns the input; `run` with a position-dependent synthetic body vs a numpy port | exact for plans, absolute 1e-6 | Linux |
| P4 packing | pack/unpack round trip and all 4 patterns vs `to_rggb`/`from_rggb`; normalization vs `raw.load`; odd edge row and column untouched | exact | Linux |
| P5 decode equivalence | `CIRAWFilter(ARW/RW2)` vs `CIRAWFilter(converted DNG, not denoised)` with the same recipe | identical `nativePixelSize`; mean dE2000 below 0.5 and p99 below 1.5 after Lumen's render. On failure use the A fallback in section 2. | Mac |
| P6 model | `Denoise/scripts/coreml_parity.py`: Core ML vs PyTorch fp32 `Denoiser` on identical inputs, synthetic cases at ISO 100, 1600, 6400 and 25600 (model-level 256x256, 64x48, 512x768, 1024x1024; tiled 1300x1900), every RAW on its command line, and its fixture cases. Then the Swift runner on those fixtures. | every Core ML output finite and at least 50 dB PSNR in `train.tone()` space vs torch fp32 (the script's exit status); Swift runner output within max abs 2e-3 of the fixtures' `expected_coreml` | Mac |
| P7 full image | Swift pre-pass CFA (uint16) vs `infer.py --strength 1.0` CFA, 3 files per camera | 99% of pixels within 4 DN, max 16 DN; PSNR gain against the noisy input within 0.05 dB of Python's | Mac |
| P8 round trip | denoised DNG re-read; untouched pixels outside the packed region identical; BlackLevel, WhiteLevel and CFAPattern unchanged | exact | Mac |

Precision note:
- The std map stays Float32, as in training (`train.py` runs fp32). Python inference (`infer.py`) computes it on the `.half()` tile, and at ISO 100 and below its intermediate `K*sig + r` is subnormal in fp16 (`r` is about 1.26e-7 for the A7 IV), so `infer.py`'s std map is about 5-8% off the fp32 one.
- Lumen deliberately matches the fp32 training std map, not `infer.py`'s fp16 one: Swift computes it in Float32 and casts `std` (about 3.5e-4 or more, a normal fp16 value) to Float16 only at the model input. P6 is measured against fp32 PyTorch for that reason, and the parity fixtures use the fp32 `train.std_map`, including a low-ISO case (ILCE-7M4 ISO 100).
- For P7 at ISO 100 and below, stock `infer.py` is therefore not the right reference: run the Python side with the std map computed in fp32 (`std_map(tt.float(), K, rv)`), or the 5-8% std-map difference shows up as a Swift error.
- Output quantization: fp16 near 1.0 is about 8 DN. If P7 fails in highlights, export with the final `noisy + s*net(x)` multiply-add kept in fp32 (coremltools `op_selector`) and a Float32 `denoised` output. The runner should read the output `MLMultiArray`'s `dataType` and accept both. Any change to the I/O dtype is a contract change and must be recorded here.

## 7. Checklist for the main session on the Mac

1. **Pick the weights.** Use the winning checkpoint from runs A and B as `Denoise/weights/lumen_denoise.pt`, and confirm `residual_flag` is in its state dict. Do not commit weights, packages or fixtures.
2. **Export and run the parity gate** (details and expected output: [`COREML_EXPORT.md`](COREML_EXPORT.md)). From `Denoise/` in the venv, after `.venv/bin/pip install "coremltools==9.0"`:
   ```sh
   .venv/bin/python scripts/export_coreml.py \
       --weights weights/lumen_denoise.pt --calib weights/calib.json \
       --out weights/lumen_denoise.mlpackage
   .venv/bin/python scripts/coreml_parity.py <A7 IV high-ISO .ARW> <GX85 high-ISO .RW2> \
       --mlmodel weights/lumen_denoise.mlpackage \
       --weights weights/lumen_denoise.pt --calib weights/calib.json \
       --compute-units ALL,CPU_AND_GPU --json reports/coreml_parity.json
   ```
   - The export writes `weights/lumen_denoise.mlpackage` and `weights/lumen_denoise.coreml.json`, with `model_id` and `calib_digest` also in the package metadata (section 4.1).
   - The parity run must end with `"result": "PASS"` (P6). It also writes the Swift fixtures to `weights/coreml_fixtures/` (`manifest.json` plus `.bin`/`.npy` per array), computed with the first `--compute-units` entry.
   - The default export is RangeDim; keep the runner on `.all` or `.cpuAndGPU`. Only if the ANE is wanted, re-export with `--enumerated 1024x1024,...` and re-run parity with `--compute-units CPU_AND_NE,ALL` after checking ANE placement (section 4.4).
3. **Build and test the branch with the model and fixtures.** From the repo root:
   - `git fetch && git checkout claude/denoise-integration` (or the PR branch).
   - `swift build`.
   - `swift test --filter LumenCoreTests.RawDenoise`.
   - `LUMEN_DENOISE_MLMODEL=$PWD/Denoise/weights/lumen_denoise.mlpackage LUMEN_DENOISE_FIXTURES=$PWD/Denoise/weights/coreml_fixtures swift test --filter LumenPipelineTests`. The runner's fixture test (second half of P6) skips without both variables, so a green run without them proves nothing about the model.
4. **Implement the follow-ups**, in this order, each behind the flag:
   - a `RawCFAProvider` conformer (DNG raw-IFD reader, section 2 step 1), checked against rawpy's `raw_image_visible` crop and 2x2 phase;
   - the DNG patcher (section 2 step 5) and the swap-DNG tier with payload-file deletion (section 4.5);
   - `DenoisedRawSource` and the swap at `RenderCoordinator.swift:932-934` (section 4.3), constructing `RawDenoiseCoreMLRunner(modelURL:)` with an explicit URL (`Denoise/weights/lumen_denoise.mlpackage` during development; the runner does not search for it) and loading `Denoise/weights/calib.json`;
   - the `Denoise.appleStandIn` change for the pending state (section 4.2);
   - consulting `RawDenoiseFeature.isEnabled` at the source construction site and in the panel (section 5).
5. **Measure P5 first** (section 6). If the colour gate fails, switch the blend's original side to the converted DNG before any UI work.
6. **Run P7 and P8** on 3 A7 IV and 3 GX85 files covering ISO 100 to 25600, at least one at the table edge (A7 IV ISO 51200, GX85 ISO 25600). Use the fp32 std-map reference at ISO 100 and below (section 6). Confirm the GX85 CFAPattern from the converted DNG (open question in `Denoise/docs/model_research.md:178`).
   - Record timings per photo and the compute units used.
   - Write results to `Denoise/reports/coreml_parity.md`.
7. **Enable the flag** with `LUMEN_RAW_DENOISE=1 swift run LumenApp`. A bundled `.app` needs `launchctl setenv LUMEN_RAW_DENOISE 1` before launch.
8. **Smoke test** in the app:
   - Open a high-ISO ARW and an RW2, turn on AI denoise, and check the "computing" badge, then the swap without a flash of a wrong frame.
   - Drag strength 0 to 100: it should be instant, with no re-run in Console. Strength 0 should look the same while pending and once ready (section 4.3).
   - Toggle off and on: the cache is hit.
   - Edit WB and exposure: no re-run.
   - Check masks and spots still line up.
   - Export JPEG and TIFF at full size, and confirm the result matches the viewer.
   - Quit and relaunch: the artifact is reused.
   - Delete the photo: the swap DNG file is removed from disk, not just its row.
   - Uninstall or rename the converter: there is a clear error and the fallback rendering.
9. **CI:** confirm `fixtures-linux`, `engine-linux`, `build-macos` and `test-fast` are green on the PR branch. CI runs on push; there is no `pull_request` trigger.
