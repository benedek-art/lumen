# Cloud continuation checkpoint — 18 October 2026

Owner requested an extended accuracy/reliability audit for editing real RAW photographs, with separate editor and denoise workstreams. Owner then explicitly requested a safe stop and cloud continuation because the Mac will be turned off. This is a work-in-progress checkpoint, not a release or installed-app qualification.

## Source and safety

Started at main 3219754. Work is on codex/raw-accuracy-qualification. No pixel algorithms or saved-look defaults were retuned. No installed application or updater release was changed. The installed app was still a September revision. Private originals remain on the owner's external drive and were only read. No photographs, inventories, private paths, catalogs, screenshots or diagnostic image crops belong in GitHub or cloud uploads.

Implemented changes: malformed/future recipe containment; failed catalog-registration isolation; refusal to publish recipe/culling sidecars after failed catalog writes; exact-byte detected-XMP-conflict retention plus named snapshots when dependencies validate; numeric slider text sessions bound to photo/batch/mask/component/swatch targets; honest decoder sharpening labels; explicit environment-based isolated native qualification launch; opt-in real RAW tests.

## Executed evidence

- Clean optimized build using current swiftbuild engine, debug info disabled: 28 selected app tests passed, including four sidecar-conflict/culling tests, four numeric-entry tests, 13 smart-source/containment tests and seven inventory self-checks. Three new denoise ground-truth tests also passed. Check exact test discovery when rerunning.
- Earlier full compiled suite: 3,238 tests, 28 intentional skips, one stale source-citation failure. Citations subsequently regenerated from original baseline and all seven inventory self-checks passed in the clean build. A final full suite for all newest changes is still owed.
- Independent colour-kernel accuracy on six actual camera-photo distributions passed (registered colour endpoints/midpoints, existing f32 conditioning-aware gate unchanged).
- Native isolated Classic denoise: 16 photographs x three regions x 20 variants = 960 measured crops, all finite; all 48 zero-strength regions matched Off exactly. This is response/parity evidence, not calibrated aesthetic quality.
- Actual displayed denoise: completed 16 photographs; 16 assertions failed. AI amount zero differed from Off ONLY in the first region of each photo, max 1–4 encoded values; other regions and returning to Off matched exactly. Do not loosen the assertion. Leading unproven hypothesis: AppleRawSource's first native legacy decode remains lazy, while a later cache hit promotes to half-float materialized pixels. Off-return can evict/recreate the lazy path. Investigate decode materialization/precision and first-versus-cache rendering.
- Full drive metadata inventory: 13,059 readable RAWs, Sony A7 IV and Panasonic GX85. Detailed copied set contains 38 files with ISO/exposure/orientation extremes. These private assets are LOCAL ONLY and unavailable after shutdown.
- Interrupted global preview sweep after 650 completed control/photo sweeps of 21 settings each; progress is not whole-suite success. Interrupted broad default-preview pass after 172 rendered-file records. Local native adjustment sweep was interrupted and has no overall pass result. Preserve original logs locally; do not infer completion.

## Build/tool pitfalls

Native deprecated build engine repeatedly emitted build-database I/O errors and sometimes ran a STALE test bundle despite reporting completion. Do not count those runs. Reliable clean build used:

    swift test --build-system swiftbuild -debug-info-format none -c release --disable-sandbox --scratch-path /private/tmp/lumen-qualification-01a14db6 --filter 'SmartAlbumSourceTests|SidecarConflictRetentionTests|SliderNumericEntrySessionTests|LayoutMetricSelfTests|DenoiseQualificationTests'

The fresh build has separate LumenCoreTests/LumenPipelineTests/LumenAppTests xctest bundles. Verify new test names and counts, rather than trusting build completion alone. Source files must remain frozen during compilation. If UI source line numbers move, reset LayoutMetricSupport.swift from its known baseline then run scripts/recite-slider-inventory.py BASE --write once; do not repeatedly remap already shifted citations against the old baseline.

## Cloud priorities

1. Review the WIP changes and run a final full suite and source checks on exact-source CI. Preserve honest skips and known expected slider precision-floor assertions.
2. Reproduce first-native versus cached decode numerical differences with public/licensed RAW fixtures on macOS CI. The private-camera finding is not yet a proven root cause. Fix genuine render inconsistency with causal regression; keep existing accuracy tolerances and records unless independently justified.
3. Independently review conflict preservation, load refusal and target-bound numeric entry. Existing conflict detection still uses second-level sidecar timestamps, so same-timestamp rewrites can evade it. Recovery files currently have no automatic pruning. Unavailable-photo rows remain in catalog counts but are omitted from editable grids.
4. Qualify actual preview/export and native masking/texture behavior. Opt-in tests distinguish synthetic oracle agreement, quantized response, mask compositing and subjective appearance; none establishes Adobe equivalence. Native GUI pointer acceptance and a freshly built usable candidate remain owed.
5. Denoise: Classic is shipped VST/wavelet processing. AI is explicitly Apple RAW decoder denoise, with no bundled neural model. NoiseProfile.forISO is a generic full-frame seed used for both cameras; estimator exists without a production caller. GX85 ISO25600 shows substantial residual noise even at full Classic strength. Do not enable an unvalidated estimator/model or silently restyle saved recipes to make synthetic scores look better.

Cloud has no access to the external drive or local crops. Continue source work and public-fixture/hosted CI validation; clearly separate work blocked on the Mac/photos. Do not publish a release, replace the installed app, upload private data or claim exhaustive real-photo acceptance. A source draft PR is appropriate after review/verification.
