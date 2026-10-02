# P8-raw: RAW decode correctness, and RAW tests that can fail on CI

Stream agent P8-raw. Base: `claude/jolly-sagan-k7ch7z` at `5029bc3`. The worktree branch is
`worktree-agent-a51df21baca2d8914`. Build dir `/tmp/lumen-build-p8`, Linux. Input:
`docs/audit-2026-10/verify/V4-colour-raw.md`, "Phase 2 specs" 1–3. Also re-checked: September items
E1-02, E1-03, D2-01 and K-090.

LumenPipeline, LumenApp and the workflow cannot run here. Their changes are **source-verified**:
each was traced by hand against the old code, and the guard script was extracted from the
workflow and run on fabricated logs. The LumenCore halves run on Linux and were shown red with
the fix substituted out.

## Items

| Item | Status | Commit | Red / green | Proof records that move |
|---|---|---|---|---|
| AI-01 gap: RAW9 boundary chosen by `rawValue == "9"` | **FIXED** | `6851514` | Linux `RawDecoderNumberTests`: 1 red with the predicate reverted to `== "9"`, 2 red with the call site reverted. 3/3 green. macOS `RawDecodeBoundaryTests.testTheRaw9BoundaryIsChosenByDecoderNumberNotSpelling` is source-verified | none |
| AI-01/AI-15: `AuditRawAccuracyTests` never ran on CI | **FIXED** (source-verified; first lane run pending) | `028f754` | Guard script run on a fabricated log: it passes the counts, fails on a skipped non-RAW9 test, and prints the RAW9 skip into the summary. Traced red cases are listed below | none |
| V4 "decoder pin" decision | **SPEC ONLY** (format decision) | – | – | – |
| E1-02 AI stand-in on rendered files | **FIXED** (the open remainder) | `089ab26` | `AIDenoiseRenderedHelpTests`: 2 red with the old tooltip, 1/1 green | none |
| E1-03 noise-profile estimator bias | **PARTIAL** | `7ee0bc4` | `NoiseProfileEstimateTests`: 3 red (1.338×, 1.349×, 1.590×), 3/3 green (0.9997×, 1.008×, 0.984×, flat 0.999×). `DenoiseTests` 20/20 | none (no caller) |
| D2-01 Texture selects by contrast | **NOT-FIXED**: re-verified open; spec under DECISIONS | – | – | – |
| K-090 GPU Dehaze sky guard | **NOT-FIXED**: re-verified open; spec under DECISIONS | – | – | – |

### AI-01: one decoder normalization (`6851514`)

`AppleRawSource.decode` chose the RAW9 colour boundary with `filter.decoderVersion.rawValue == "9"`.
Every other decoder comparison in the file used digits. A RAW9 DNG decoder spelled `"9.dng"`
(following `version8DNG == "8.dng"`) would skip the boundary, and its lazy image would be evaluated
in the Rec2020 working context. That is the cyan decode AI-01 reproduced. It was reachable two
ways: as Apple's per-file default, or through an explicit pin of 9, which the numeric
`resolvedVersion` match does resolve to `"9.dng"`.

- `RawParams.decoderNumber(_:)` and `RawParams.needsRaw9ColourBoundary(_:)` live in LumenCore
  (`Recipe.swift`). They use the same digits-only reading the pin has always been written with,
  so no persisted pin changes meaning.
- `AppleRawSource.needsRaw9Boundary(_ : CIRAWDecoderVersion)` wraps that predicate. The decode
  and all of `AuditRawAccuracyTests` (`supportsRaw9`, the RAW9 `versions` entry, the oracle's
  context choice, the pin lists) now go through it.
- The tests:
  - `RawDecoderNumberTests` (Linux) checks the predicate, the numbers existing pins carry, and a
    comment-stripped scan that forbids `rawValue == "`, `rawValue != "` and `filter(\.isNumber)`
    in `AppleRawSource.swift` and `AuditRawAccuracyTests.swift`.
  - The macOS twin builds `CIRAWDecoderVersion(rawValue: "9.dng")`. It uses `init(rawValue:)`,
    which every `NS_TYPED_ENUM` import has, and no platform constants, so it cannot reference a
    member that might not exist.

### AI-01/AI-15: the RAW checks on a lane that can fail (`028f754`)

`raw-corpus.yml` gets a new step that runs `swift test --filter AuditRawAccuracyTests` with
`LUMEN_AUDIT_RAW_DIR` set to the corpus directory. The step runs under `if: !cancelled()`, has a
20-minute step limit, and its log `audit-raw.log` joins the evidence artifact. The job timeout
goes from 45 to 60 minutes. A new guard step reads that log:

- Every test prints one `audit-raw-file: <test> <file> <verdict>` line per file it examined,
  refused files included. Each of the five tests must reach every positive manifest row. A
  skipped test prints nothing, so **a skip fails the lane**.
- The three tests that need no RAW9 (`unpinned`, `native-dimensions`, `pins`) also fail the lane
  if they skip, checked by name.
- The two RAW9 tests may skip, but only after reaching every file, which means no file on this
  runner offers RAW9. That skip goes into the job summary.
- The summary also shows each file's default and supported decoders, and how many files have a
  default that is **not** their last supported version. Only on those files can a return to
  forcing `.last` be seen, and the summary says whether this runner has any.

How the tests generalise from three Sony ARWs to the corpus. Each case is scoped per file; none
was loosened.

- **Manifest mode.** A directory holding `corpus.tsv` is read through the manifest. The two
  synthetic negatives are left to R-9. Logs use manifest ids. A private directory keeps ordinals,
  and its extension list now covers the corpus containers.
- **Refusals.** A file Apple's own `CIRAWFilter` will not open must make `AppleRawSource(url:)`
  throw. A file Apple opens but forms no image from, with the identical flat settings, must make
  `decode` return nil. Both are asserted, not skipped. Every other file must decode and match
  the independent filter, exactly as before.
- **AI-15 delivered size** (new). For every non-draft decode, the delivered long edge must equal
  `scale × nativeLongEdge` within 2 px. That is the finding's 5120-for-2560 symptom; the old test
  checked metadata only. If a fresh platform filter does not deliver that size for the file
  either, the file is logged (`audit-raw-scale-note:`) and Lumen is held to the platform's size.
- **The pin test no longer needs RAW9.** It pins every other decoder the OS offers for the file,
  switches back to it (a cache hit), and checks that pin 999999 renders the default. RAW9 is
  included where offered. If an offered decoder forms no image, the expectation is the default,
  which is `decode`'s own documented fallback. If the default carries no number, every pin must
  render the default.
- **One bad file no longer hides the rest.** Per-file errors become an `XCTFail` plus an `error`
  verdict line.

Traced red cases (source-verified):
- Re-forcing `supportedDecoderVersions.last` in `init` fails `unpinned` on any file whose default
  is not its last.
- Dropping `scaleFactor` from `DecodeKey` makes the 0.08 ask hit the 0.12 entry, which fails the
  delivered-size assertion.
- An unset or empty variable, a renamed class, or a moved manifest fails the guard with
  "reached 0 of 16".

What the first lane run must be read for:
- **RAW9 on `macos-15`.** It is almost certainly not offered there, so the two RAW9 tests will
  show as skipped in the summary.
- **The default-is-not-last count.** If it is 0 on this runner, the `.last` regression is still
  invisible on CI. It needs a runner whose macOS offers a newer decoder than the per-file
  default.
- **Any `audit-raw-scale-note:` lines.**

`scripts/check-release-policy.rb` passes. It reads only `ci.yml`.

### E1-02 (`089ab26`)

Re-verified against current code. 4ba50e1 already removed AI from rendered files' mode options
and discloses legacy AI recipes with a caption. Still false: the Amount tooltip on a rendered
file ended "Classic is the engine that runs." In `.ai` mode `ISODefaults.classic(for:)` zeroes
every Classic master that was not set by hand, so on a fresh recipe only Hot Pixels runs. The
tooltip now says that. `AIDenoiseRenderedHelpTests` pins both the engine fact and the code (not
comments) of the tooltip branch. LumenApp hunk: 4 lines of text plus a comment in
`DetailPanel.aiAmountHelp`.

### E1-03 (`7ee0bc4`)

Re-verified: `NoiseProfile.estimate(from:)` still has no caller, and its bias reproduces at the
audit's number (1.34× on the proof ramp; 1.59× with the ramp across the frame). Each 8×8 block
now takes its variance about a least-squares plane, over 61 degrees of freedom. The χ²
correction was updated to match: 1/0.776, Wilson–Hilferty.

Smooth ramps now come back at 0.98–1.01×. **Not fixed:** a frame with texture everywhere has no
flat block, so it still biases the estimate. With a 15% 6 px sinusoid it reads 3.18× (was
3.33×); with 2% it reads 1.05× (was 1.38×). Wiring the estimator, or deleting it, is a DECISION
(below).

### D2-01 and K-090: re-verified, not implemented

- **D2-01.** `RenderGraph.swift:678/717` still builds Texture and Clarity as `lum − guidedSelfFilter(lum)`.
  A self-guided filter's band is `ε/(var+ε)`, which selects by contrast, not by scale. The
  reference band stack (`DetailEngine.swift:270-289`) is not ported.
- **K-090.** `RenderGraph.swift:880` still passes one scalar `floorT`, and `Kernels.swift:152` is
  `max(raw, floorT)`. The negative branch's `distant` is still `1 − raw`, without
  `max(·, skyness)`.

Neither is on the RAW path. Both fixes change the look of every existing Texture, Clarity or
Dehaze edit in previews and exports, so the brief says to spec them rather than implement them.
See DECISIONS.

## DECISIONS

1. **Decoder pin (V4).** Not written into the recipe. Today nothing writes
   `develop.raw.decoderVersion`. `AppleRawSource` pins Apple's per-file default only for the
   lifetime of the source object, and `CaptureMetadata.decoderVersion` has no consumer. So when a
   macOS update changes a file's default decoder, renders shift, and the fingerprint (`dv=-`) does
   not notice. If the owner wants first open to write the pin, these are the consequences:
   - **Fingerprint and cache churn, once.** Every RAW recipe's fingerprint goes from `dv=-` to
     `dv=N` on first open after the change ships. Previews, thumbnails and every cache keyed on
     the fingerprint are invalidated and re-rendered once per photo. The pixels are identical, so
     no proof record moves; it costs only time.
   - **It must be a silent write.** It must not enter undo history, must not mark the photo as
     edited (`CatalogService` measures `edited` against the as-opened recipe), and must not bump
     the edit revision in a way that triggers sidecar writes from a read-only or compare view.
     That means a dedicated "stamp pin" path, not `binder.edit`.
   - **It can only capture today's default.** A recipe edited before the pin ships gets pinned to
     whatever the OS offers at the moment it is next opened. Drift that already happened cannot
     be undone, because the historical decoder was never recorded anywhere.
   - **The `Int` format cannot pin a DNG variant faithfully.** The pin stores the number: "8" and
     "8.dng" are both 8, and resolution takes the *first* supported decoder with that number. On
     the OS that wrote the pin, `requested == pinnedDecoderVersion` routes to the exact default,
     so it is correct. On a later OS whose default for that DNG has moved on, pin 8 resolves to
     the first "8"-numbered entry, which may be the non-DNG decoder. Pinning faithfully needs the
     identifier string. That is a recipe format change: decode `Int` or `String`, write
     `String`, keep the fingerprint `dv=` text stable for existing integer pins.
   - **Snapshots, looks and paste.** A snapshot or history state taken before the stamp carries
     `nil`. Restoring it unpins the photo, unless restore keeps the current pin when the restored
     value is `nil`. A pin is per file, so it must not travel between photos. Looks already
     leave Develop alone, `raw` included (`SavedLookTests.loadedDevelop` asserts it), but
     paste-settings and sync must exclude `raw.decoderVersion` too.
   - **Alternative that leaves the format alone:** store the pin in the catalog per photo and
     feed it into the fingerprint, not the recipe. It loses sidecar portability.
2. **E1-02 engine half.** I left legacy AI recipes on rendered files as they render today
   (Classic zeroed, Hot Pixels only). The finding proposed making `.ai` keep Classic's defaults
   until a Tier-2 artifact exists. Done for all files, that double-denoises RAW (Apple stand-in
   plus Classic). Done for rendered files only, it needs the source kind threaded into
   `RenderPlan`. Either way it changes the pixels of existing AI recipes.
3. **E1-03.** Wire `estimate(from:)` (per camera and ISO, cached in the catalog, as docs/07 §2.4
   specifies; it now handles smooth gradients, but texture-dominated frames still need a
   mode-of-variance or flat-block rejection step), or delete it and the "profiled" language.
4. **K-090 spec.**
   - Pass two more planes to `lumenDehaze`: log-luminance in EV (`RenderGraph` already builds the
     LumenLog plane for the guide; multiply by `LumenLog.range`) and the gradient magnitude the
     reference uses (`Decomposition.gradient`, in EV per pixel at the decode's scale).
   - In the kernel: `bright = smoothstep(0.5, 2.0, logLumEV)`,
     `flat = 1 − smoothstep(0.05, 0.35, grad)`, `floorT = mix(tMin, 0.9, clamp(bright·flat, 0, 1))`.
   - Negative branch: `distant = max(1 − raw, skyness)`.
   - Moves `detail.dehaze` (V4/D2 measured the sky at +0.69 EV mean at +100) and any look record
     with Dehaze ≠ 0. The kernel roster and `KernelGoldenTests` change with it.
5. **D2-01 spec.** Move Texture and Clarity onto the à-trous band stack that S12 sharpening
   already builds on the GPU (`RenderGraph.fineDetailBand`, `bSpline5`), weighted by the
   reference's raised-cosine window around `bandCenter(longEdge)`. Moves `detail.texture` and
   `detail.clarity`, and changes the look of every Texture and Clarity edit.

## FOUND-WHILE-FIXING

- The RAW9 predicate is `== 9`. If a future RAW10 has the same wide-working-space evaluation
  defect, it will not get the boundary. That is deliberate: no behaviour is invented for an
  untested decoder. The corpus lane's decoder summary is where a RAW10 would first appear.
- `AppleRawSource.decode` keys a cache entry by the **requested** decoder even when it fell back
  to the default because the requested one formed no image. A later request for the same pin hits
  the same fallback pixels, so this is harmless, but the key's `decoderVersion` field does not say
  which decoder produced the pixels.
- `raw-corpus.yml` triggers only on its own path. Changes to `AuditRawAccuracyTests.swift` or
  `AppleRawSource.swift` do not run it. Adding the test file to `paths` is cheap and in the
  spirit of the header. I left the trigger alone, because the header ties widening the trigger to
  three green dispatched runs.
- `macos-15` probably offers no RAW9 decoder, so the RAW9 colour boundary is still unexercised on
  CI. The lane summary now says so on every run instead of passing silently.

## Checks

- `swift build --build-tests --scratch-path /tmp/lumen-build-p8`: clean.
- Suites green: RawDecoderNumberTests 3/3, NoiseProfileEstimateTests 3/3,
  AIDenoiseRenderedHelpTests 1/1, DenoiseTests 20/20.
- `python3 scripts/check-swift-surface.py`: exit 0.
- `ruby scripts/check-release-policy.rb`: passes.
- Nothing pushed.
