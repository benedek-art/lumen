# Cloud continuation evidence

Starting checkpoint: `0f57d65710e8f13b919a06257825507bdd6ff1b4`, branch `codex/raw-accuracy-qualification`. Read CLOUD-HANDOFF.md for executed private-photo evidence and interruptions. No private assets are available here. No release, installation or main merge is authorized.

## Reviewed repairs awaiting native execution

1. Pending sidecar debt recovery used `currentRecipe` and clamped future pipeline versions on reopen, bypassing ordinary load containment. Recovery now uses the same checked recipe reader and leaves unreadable/future debt and sidecar bytes intact. New regression covers malformed JSON, future database version and future embedded version. Quit reports debt rejected before it could be queued.
2. New conflict-snapshot database work in `flushSidecars` could run outside the catalog serial queue. That block now hops onto the queue with a reentrant queue-specific guard. Filesystem reader adapters retain their existing concurrency behavior. Source-confirmed race repair; no executed race reproduction claimed.
3. Opening a rounded slider readout and submitting unchanged text converted a stored value such as 1.234 to 1. Sessions now retain initial text and return the original value for untouched submissions; no-op submission emits no edit events. Two new session tests cover precision, stale targets/values, real edits, arithmetic and preservation of existing out-of-range values. Native focus/pointer ordering remains unqualified.

No pixel algorithm, math tolerance, golden or creative default was changed. Slider source citations remapped once from the checkpoint baseline (two moved, zero unplaced).

## Public RAW first/cache investigation

Hosted RAW corpus lane now selects only its existing SHA-verified CC0 Sony A450 and Panasonic GH5S fixtures for native precision measurements and the unchanged exact displayed Off/AI-zero/Off-return check. These are public camera files, not the owner's A7 IV/GX85 acceptance set. Diagnostic logs measure lazy repeat, explicit half-float materialization, cache promotion and cached repeat before RenderPlan/display/dither. Raw first/cache differences are observations; the display exact-zero assertion is not weakened. Repeated evaluation of the same lazy/cached graph is asserted identical. Public-only evidence is uploaded by the existing corpus lane.

No decoder production fix has been justified yet. Half-float promotion remains a hypothesis until hosted evidence is available.

## Executed cloud checks

- `python3 scripts/test-check-swift-surface.py`: all 41 positive/negative fixtures passed.
- `python3 scripts/check-swift-surface.py`: passed on the starting checkout; rerun owed after integrated edits.
- `python3 scripts/test-gen-slider-atlas.py`: all canonical-file precedence cases passed.
- `python3 scripts/test-publish-staged-release.py`: 18 offline tests passed. No release action occurred.
- `git diff --check`: passed after repairs/citation remap.
- Native Swift and Ruby are absent from this Linux runtime. No native compilation, full suite, camera acceptance or release-policy Ruby pass is claimed locally.

## Outstanding gates

Complete exact-source optimized macOS suite and proof/GPU/layout/corpus results must be inspected, including discovered counts and skips. Public RAW fixture fetch/runner availability can block measurements. Existing second-resolution sidecar change detection, no recovery pruning, per-field culling partial transactions and unavailable-photo count/grid differences remain limitations. Do not present fixes as passed until causal native tests execute.

Tomorrow: private A7 IV/GX85 first-native and cached/Off-return reproduction, copied-shoot preview/export roundtrip, masks/texture/heal edges and detail/noise review, keyboard/focus/target-switch/undo ordering, physical removable-volume failures and original-byte preservation. Camera/colorimetric calibration and subjective aesthetics remain independent of mathematical/GPU agreement.

## First cloud revision: 5ced9c3

Draft PR: https://github.com/benedek-art/lumen/pull/10 . All results below belong to `5ced9c3d0940413303cc34a54c9311bb29a7d9a7`, not subsequent repairs.

- CI https://github.com/benedek-art/lumen/actions/runs/39106714587 : build and app bundle passed. Linux engine completed 2,603 selected tests successfully (parallel XCTest progress count); full optimized macOS suite still running at this checkpoint. Fixtures/source-check job failed solely because the known-platform symbol list lacked SDK type `DispatchSpecificKey`; follow-up adds that real type. Release-validation was intentionally skipped on this non-main branch. No release was attempted.
- Layout https://github.com/benedek-art/lumen/actions/runs/39106714561 : 19 tests, zero unexpected failures; declared precision-floor expectations remain explicit.
- Proof https://github.com/benedek-art/lumen/actions/runs/39106714584 : six optimized proof tests passed; 144 evidence files. Existing records and tolerances unchanged.
- RAW https://github.com/benedek-art/lumen/actions/runs/39106714580 : failed, not accepted. Twelve corpus tests produced five assertion failures: guessed neutral-chroma alarm on Nikon Z30 (39.28) and Panasonic GH5S (23.22) against the existing 20 threshold, plus three all-black-content assertions on Leica Monochrom1087. Thresholds were retained. Independent Apple-default/flat-option and ImageIO sweep also yielded flat black for Leica; production cause remains unproven. Four files had no usable Apple decoder on this runner. Decoder-selection tests reached every public fixture, six tests executed, two RAW9-only skips, zero failures; RAW9 unavailable here is a real coverage gap.
- The broad decoder-selection filter also executed the newly added native precision method on all 16 public rows. Twelve decoded; five showed first/cache differences. Max absolute scene-linear Float deltas: Canon1346 0.009951226, Nikon5812 0.0039727464, Sony2349 0.00003042072, OM5283 0.0044733062, Leica1087 0.0000031795353. For each, explicit materialization versus promoted cache was exactly zero; repeat evaluation of either same lazy or same cached graph was exactly zero. This isolates a decode/materialization numerical boundary before plans/dither, but does not yet prove the displayed mismatch cause.
- Urgent displayed check did NOT execute pixels: fixture isolation was skipped after prior corpus failure; the later always-run check failed for a missing input directory. Follow-up makes setup/diagnostics run despite independent corpus failures, while still validating available pinned inputs. No display identity pass or product failure inferred from missing-directory infrastructure.

The initial workflow lookup used a wrapper that filters pull-request events and therefore missed push runs. Direct `github.fetch` of Actions runs with `head_sha` is now used. Checkpoint0f57d65 had a successful layout run and incomplete/cancelled other runs, not proof of absent CI.

## Prepared follow-up, awaiting exact-source hosted qualification

- Atomic culling fields: one UPDATE/transaction prevents a rejected rating/label from committing an earlier flag. New core trigger regression and stronger app failure regression check complete prior state and unchanged sidecar.
- Off-grid outward nudge: Exposure6.234 increment previously returned6.23, and6.236 returned6.24. Compiling the actual baseline SliderDrag.swift and the corrected source with the same independent exact-hold probe produced8/8 failures before and0/8 after for signed6.234/6.236 and single/ten ticks. The16 SliderNudgeTests also passed on Linux. Existing zero-tick normalization is preserved.
- Numeric mixer sessions additionally bind selected band and All-bands mode; a same-value async band change must invalidate entry. Added session regression. Native focus ordering remains pending.
- Sidecar recovery now preserves entire debt on thrown photo/keyword reads; validates all referenced painting blobs and refuses partial/missing/oversized portable payloads. Regression removes one/all blobs, checks exact sidecar+debt preservation, restores blobs, and retries. Ordinary saveRecipe publication needs separate missing-dependency review; this repair specifically covers durable recovery.
- Two independent mask geometry oracles use explicit pixel permutations for crop/reflection/quarter turns, not production geometry helpers. No new production mask defect was established; native execution pending.
- A ten-pair displayed causal matrix holds lazy/materialized images fixed while varying renderer/plan reuse and mode order. Records native edge and first/repeated residency so below4096 negative controls are identified. Strict equality remains unchanged. Broad decoder filter excludes these dedicated diagnostic methods to avoid accidental duplicate work.
- Corrected denoise Detail tooltip: increasing Detail lowers the shared CPU/GPU shrinkage threshold, rather than raising it. No denoise math changed.

Cloud now has a user-space Swift6.1.2 toolchain. Initial Linux target build lacked SQLite headers and omitted catalog tests, so it is NOT catalog acceptance. Dependencies were supplied and a fresh SQLite-enabled build is required to discover CatalogCullingAtomicityTests. First parallel launch stalled in runtime backtrace; no pass is claimed for that aborted invocation. Direct serial nudge XCTest ran16 tests successfully. Parse passes succeeded for Sources and each test module separately. Frozen source checker passed; all41 checker fixtures passed.

Authorized window: eight hours from the owner's update; hourly continuation checkpoints and an eight-hour report were scheduled. This records intended scheduling, not eight hours of completed work.

Follow-up local frozen SQLite-enabled qualification: `swift test -c release --scratch-path /workspace/scratch/2982a056243e/build-sqlite --filter 'SliderNudgeTests|CatalogCullingAtomicityTests'` passed17 tests, zero skips/failures. CatalogCullingAtomicityTests was positively discovered and passed, so SQLite was active. SWIFT_BACKTRACE=enable=no avoided the parallel-runtime backtrace issue; serial XCTest selection used. Full macOS app/pipeline execution remains separate.

GPU lane at5ced9c3 completed successfully: https://github.com/benedek-art/lumen/actions/runs/39106714591 ,222 tests,23 intentional opt-in skips,zero failures.

Independent Leica content check: pinned CC0 fixture1087 SHA256 `3fb74d1fc402daaa48a9c3f1d6279d7e85fb58dfdaf816f036927d49ab228977`,21,700,096bytes, decoded with rawpy0.27.1/LibRaw0.22.1/NumPy2.5.4. Raw5984x4000 one-channel samples min0,max3947,mean266.64772017,std232.01470442;23,935,985/23,936,000 nonzero. Linear16-bit(no_auto_bright,gamma1,1) min0,max65535,mean4659.42895755,std4054.61010165; normalized mean0.07109955. Default8-bit mean108.91646060,std52.86200732. Fixture contains image detail; hosted Apple-default/flat/ImageIO black is not a genuinely empty scene. This establishes content, not decoder-equivalent colorimetry. Exact stats saved as public-leica-independent.json; reproduction script accepts the public pinned fixture. No photos are committed.

## Integrated follow-up: fa79116

Reviewed source and tests were fast-forwarded onto the owner's checkpoint branch as `fa791166643b3e89ddda42d61207cc3256d82c80`. Previous runs were complete before this push. Draft PR10 stays open/unmerged.

First cloud full optimized Mac result at5ced9c3 is now final: **3,253 tests executed,31 intentional skips,zero failures**. New future-recipe recovery and all six numeric-entry session tests were positively discovered and passed. Full CI was still red because the separate surface-checker symbol table failed; RAW corpus was independently red as recorded above. A full-suite pass does not certify those camera/alarm failures.

Exact follow-up runs (pending when recorded):
- CI https://github.com/benedek-art/lumen/actions/runs/39107765110
- GPU https://github.com/benedek-art/lumen/actions/runs/39107764959
- Layout https://github.com/benedek-art/lumen/actions/runs/39107764982
- Public RAW https://github.com/benedek-art/lumen/actions/runs/39107765012
- Proof https://github.com/benedek-art/lumen/actions/runs/39107764963

Local opt-in CPU bookkeeping benchmark on frozen follow-up source, Swift6.1.2 Linux release: `LUMEN_BENCH=1 swift test -c release --scratch-path ... --skip-build --filter SpeedBenchTests` passed one test. RenderPlan default0.037ms, exposure0.026ms, moving-slider cache-miss0.028ms, grade wheel0.063ms, vignette0.027ms,parametric curve0.058ms. These are a small hosted CPU microbenchmark with no baseline comparison, not displayed latency, RAW decode cost or photographer responsiveness. Denoise-plan values rounded to0.000ms and are below this print resolution, not zero-cost processing.

Continue from fa79116's hosted diagnostics before a production decode change. Keep same-timestamp sidecar detection, ordinary recipe publication with missing painting blobs, decoder identifier aliases6/6.dng, and the Leica platform failure as explicit independent investigations. Do not convert guessed chroma alarms to passes or blacklist all dark photographs.
