# 23 — The master plan

> Status lives in three places only: the proof records, the CI lane results, and the
> checkboxes in THIS file, updated in the same commit as the work. Every other document
> in this repository may be stale; this one may not. If a checkbox and a commit
> disagree, the commit is wrong.

## Why this document exists

The owner used the app twice on a real Mac and found it broken, slow, and clunky. A
three-way audit (engine, app layer, verification state) plus a design pass produced the
diagnosis below and this plan. The goal, decided by the owner:

- **Daily driver + darkroom.** The basics at Lightroom level or better (open a folder ·
  cull with flags · white balance · six tone sliders · curve · HSL ·
  Texture/Clarity/Dehaze · gradient mask · brush mask · sharpen · denoise · crop · save
  a look · apply look · export) plus culling speed plus the film/grading layer.
  Explicitly OUT: pano, HDR merge, tethering, print, full competitor parity. Doc 19's
  narrowing is re-adopted; doc 21's re-widening is dropped.
- **Owner tests after every milestone.** A CI-built app, a scripted 15–30 min checklist,
  observations in plain words. Nothing advances unverified — the rule whose absence
  produced two rounds of "fixed" responsiveness nobody had seen.
- **AI is Apple-only for now.** Vision masks ship; the Tier-2 denoise harness gets a
  stub; no model acquisition.

## The diagnosis, in one place

Why the sliders feel broken — the mechanisms, found and ranked:

1. **Draft renders switch off half the pipeline.** Every drag renders with denoise,
   presence, ALL masks, sharpening, halation, local curves and grain gated out
   (`RenderGraph.build` draft gates; `PipelineRenderer.makeGraph` returns an empty mask
   graph in draft). The picture jumps on release. (DETAIL-20.)
2. **The wrong sliders are expensive.** Whites/Blacks/curve/mixer/wheels cold-bake one
   or two 33³ LUTs (23.7+ ms) per drag frame on the render actor; Exposure hits cache.
3. **Main-thread waste per mouse event**: one ObservableObject with 56 @Published
   re-bodies every view per event; FilterBar does 14 full `allPhotos` scans per body
   pass; ScopesView rasterizes up to ~197k px in `body`; a single-entry decode cache is
   thrashed by six consumers; `onEditingChanged` is consumed by nobody, so SQLite
   writes + fingerprints are per-event; export runs on the viewer's render actor.
4. **Engine defects**: tint's magenta half silently dead on warm frames (`tintLimit`
   unsurfaced); suspected 5th units bug — the tone mask's guided ε=0.004 on a
   LumenLog-encoded plane ≈ a 1.52 EV edge threshold; Texture 1.8–17× under reference;
   Clarity ships a single-band approximation of the local Laplacian that exists only in
   `ReferenceRenderer`; preview is 8-bit undithered.

Root cause of six days of churn: the app was built blind. The only whole-graph
GPU-vs-reference goldens live in a lane that had NEVER run when this plan was written;
LumenApp (39% of the code) has no test target; the proof lane was red at HEAD with two
knowingly-stale records; verification effort flowed to what Linux could check, not to
what the owner touches.

---

## M0 — The verification loop works again

- [x] HEAD compiled by CI. (Corrected diagnosis: runs #182–184 were NOT transient —
      GitHub refuses to create jobs for a workflow whose `run:` script embeds
      `${{ inputs.* }}` inline; a one-job canary on the same push allocated fine while
      CI zero-jobbed. The expression moved back to the `env:` block where it ran 181
      times; run #185 allocated jobs and is the proof.)
- [x] ~~Dispatch gpu-parity~~ → better: the dispatch APIs 403 for this session, so the
      lane now **triggers itself** — `gpu-parity.yml` runs on any push touching
      LumenPipeline/Engine/Image/Color or the pipeline tests (its own file included, so
      the push that created it is its first run ever). **First run (gpu-parity #1,
      2026-08-24 21:02): 48 tests, 0 failures, 0 skips, 35s on an arm64 GPU runner —
      including `testGraphMatchesTheReferenceRendererOnTheColourPath` (2.18s) and
      `testGraphMatchesTheReferenceRendererWithTheSpatialStagesOn` (4.62s), executed
      for the first time in the project's history and green.** Nothing to triage; the
      known caveat stands that the spatial tolerance is a 0.25 smoke bound, to be
      tightened by measurement in M3.
- [x] The two stale proof records re-pinned (tone.exposure ±2→±5 authority 169.07→
      251.54, raw.tint ±100→±150 authority 100.13→154.97), measured locally on the same
      Swift 6.1.2 the lane runs, matching run 181's discarded measurement to rounding;
      the comparison was watched failing first with the stale number substituted back.
- [x] CI restructured:
      - [x] `ProofSmokeTests` (8 sentinel controls × 5 steps, ~3.5 min) runs in
            engine-linux on every push
      - [x] `gpu-parity.yml`: paths-filtered push + dispatch; skip-list guard greps
            test-fast's `--skip` names against the tree (it found one already:
            a skip naming a test 1bca87f had reshaped away)
      - [x] `proof.yml` (the 80-min full sweep): paths-filtered push + nightly +
            dispatch — on the push trigger it never survived a working session; the
            smoke sentinels are the per-push guard now
      - [ ] `perf-macos`: DEFERRED to M1 — a perf lane with no perf tests is noise;
            it lands with the latency HUD and DraftTruthfulnessTests
      - [x] `app-bundle`: KEPT on every push (deviation from the first draft of this
            plan) — Actions minutes are free on a public repo, and a per-push
            installable artifact is the ship-to-self loop
- [ ] Two owner-provided real RAW fixtures committed (<15MB total) unlocking
      AppleRawSource contract tests (as-shot neutral UNITS have never been verified),
      draft-demosaic delta, perf lane, Vision-matte tests
- [ ] De-risking probes run and recorded:
      - [x] (a) full-pipeline draft cost, gpu-parity run #2's GPU (a runner VM, weaker
            than any Mac the app will meet): gated draft → full pipeline at 1024:
            10.2 → **25.1 ms**; 1536: 16.5 → **36.3 ms**; 2048: 23.4 → **44.8 ms**.
            Decision rule was "≤60 ms at 1536 on the runner clears 35 ms on the owner's
            machine" — cleared with room. **M1a's no-stage-gating draft is viable; the
            DraftLadder should land most machines at 1536–2048.** `PerfProbeTests`
            reprints this table on every pipeline-touching push.
      - [x] (b) mask re-raster cost at 1024, release build, this container's x86 CPU
            (an M-series Mac is typically 2–4x faster): geometry-only combine
            (linear+radial) **12.8 ms**; luma-range + guided refine **190.7 ms**;
            geometry + feather-40 refine chain **105.0 ms**. Verdict: geometry-only
            masks are borderline per-frame viable; anything through the refine chain is
            not. **M1a's stale-while-drag MaskRasterCache is load-bearing, not a
            nicety.**
      - [ ] (c) draft-demosaic color delta (needs the RAW fixture)
- [x] Honesty pass: README's "nobody has run it on a Mac" + line count, CI comment test
      counts, "thirty-two kernels" (there are 33) — plus two the audits missed: the
      install script's "three tests fail here" paragraph (those tests were measured,
      re-bounded and green in 1bca87f before this plan existed; the paragraph outlived
      the failure — so the "3 known-red LUT-edge tests" this milestone budgeted for
      turned out to be already closed), and test-fast's skip roster carrying a test
      name 1bca87f had reshaped away.

**Exit gate:** full CI green including gpu-parity's first-ever run; probes measured.
**MET 2026-08-26**: ci.yml #199 + gpu-parity #8 + proof sweep #4 (66-min honest run,
all 111 records agree at HEAD with the ε fix in) all green on 7ee1dcb. Still open
inside M0, owner-blocked: the two RAW fixtures and probe (c) behind them.

## M1a — The picture answers the drag

The draft-render redesign — full pipeline at draft resolution, no stage gating:

- [x] `RenderGraph.swift`: the `!options.draft` gates are GONE (S3/S8/S11/S12/halation/
      S15b/grain); `Options.draft` renamed to `Options.maskSource`, which gates only
      S3+S8 for the two mask-source call sites — `draft` survives only at decode
- [x] `PipelineRenderer.makeGraph`: the empty-graph draft branch deleted; drafts build
      masks and the grain plate like any frame
- [x] `MaskRasterCache`: per-mask stale-while-bake (exact-hit reuse; first sight bakes
      synchronously; draft miss returns the previous raster while a single-flight
      newest-wins background bake computes the exact one; settle/export never stale).
      Keyed on canonical mask JSON + raster size + stroke counts + matte kinds + the
      S6–S10 recipe subtrees when the mask reads the picture. Policy tests in
      `MaskRasterCacheTests`; the truthfulness lock is `DraftTruthfulnessTests`
      (draft vs settle per-pixel at the same size, plus a discriminator that the
      stages are actually present). Watched-failing runs recorded in the log after
      the green baseline.
- [x] `DraftLadder` in LumenCore/Interaction (2048→1600→1280→1024 by measured draft
      time, 35 ms budget): down on ONE hot frame, up after a 12-frame streak of clear
      headroom, never above the caller's request, deaf to frames that were not its
      own answer. Six Linux tests; machinery substitutions watched failing
      (never-steps-down; streak-survives-middling). Wired per PhotoRenderModel so a
      compare pane's small frames never teach the loupe's ladder; learns from the
      same wall-time number the HUD shows
- [x] `PlanTableCache` stale-while-bake: `tableAllowingStale` returns the newest table
      in a slot while a single-flight background bake (newest-wins pending) computes
      the exact one; `RenderPlan(allowStaleTables:)` routes the finish + colorGrade
      bakes; `PipelineRenderer.renderPreview` passes `allowStaleTables: draft`; settle
      + export stay on the blocking path — the picture at rest and the exported file
      are exact by construction. Capacity 4→8. Four new Linux tests (first-request
      bakes synchronously, stale-then-converges, blocking-path-never-stale,
      40-event-burst coalesces), each watched failing with its defect substituted
      (synchronous-bake; replay-the-drag).
- [x] Gesture-in-flight signal consumed: `sliderGestureChanged` environment hook fired
      by every slider/wheel, one consumer (`AppState.sliderGesture`); catalog writes +
      fingerprints land once at release instead of per event; scope re-bin lands at
      release; the mask overlay deliberately stays live per event (it is the picture
      of the drag, and its refresh now cancels its predecessor); a gesture whose
      release the app never sees is flushed by `prepareToQuit`. (Immediate-settle at
      finger-up deferred: the 40 ms debounce already covers it.)
- [x] **`DraftTruthfulnessTests`** (macOS CI): draft vs settle at the same size on a
      recipe exercising every formerly-gated stage — the permanent lock. Green on
      gpu-parity #4 (54 tests, 0 failures); **watched failing on #5** with the
      substituted defect (maskSource: draft) — one failure, exactly this test,
      "differ by 17/255 — a stage is being gated out of one of them"; reverted on #6.

App-layer waste, low-risk first:

- [x] FilterBar's 14 counts + Sidebar's 2 filters memoised (`AppState.cullCounts`, one
      pass, invalidated with the photo cache); `selectedPhotos` memoised so
      `editTargets` stops scanning per body read. (Deviation: the counts live app-side
      for now — they will be covered by LumenAppTests when the target lands, instead
      of moving to LumenCore mid-sweep. BasicPanel's Recipe copies ride the
      `@Observable` migration.)
- [x] ScopesView rasters moved into `ScopeRaster`, built once per measurement on the
      binning task, carried on `ScopeData`; the view draws stored CGImages
- [x] AppleRawSource decode cache: single entry → 8-entry keyed LRU (six consumers —
      loupe draft/settle, compare panes, scopes, sampler — stopped evicting each other
      per event)
- [x] refreshMaskOverlay: stored task, cancelled by its successor, generation checked
      before the actor call (the claimed-too-late defect, closed in its last hideout)
- [x] PixelSampler lazy: task key carries whether any consumer (readout under cursor,
      clipping overlay, mask overlay) is live; nil otherwise
- [x] `ViewerRenderKey` (RenderRequest.swift) unified; both compare panes adopt it —
      brush blobs, mattes and the soft proof now restart their renders too — and adopt
      `DraftResolution`, killing the half/double zoom pump still live in compare
- [ ] Then, ONE isolated revert-friendly commit: AppState → `@Observable`
      (56 props, 25 sites, 19 files)
- [x] `LumenAppTests` target exists (links on Linux too — the `@main` stub);
      first tests: the memoised counts pinned against the exact reduce expressions
      they replaced
- [ ] Still owed from that bullet: keyed decode-cache test (the cache is
      macOS/LumenPipeline) and RenderKey parity across views

## M1b — Truth polish + instrumentation

- [x] The ε=0.004 tone-mask measurement (`ToneMaskEdgeTests`, Linux): CONVICTED —
      the shipped ε sat on the encoded plane (√0.004 × 24 = a 1.52 EV threshold),
      Shadows +100 haloed a 4 EV shadow/midtone edge by 0.497 EV. Deviation from the
      bullet's candidate: ε′ = 0.004/24² fails the OTHER way (the mask follows
      ±0.2 EV high-ISO noise at σ 0.090 EV); the fix is the measured knee, a 0.375 EV
      contrast threshold (halo 0.052 EV, noise σ 0.010 EV, ~2x margin to each bar),
      as `ReferenceRenderer.toneMaskContrastThresholdEV` with the conversion written
      and RenderGraph reading the same symbol. Two-sided watched-failing locks:
      shipped ε reddens the halo test at 0.497, naive ε reddens the noise test at
      0.092. Legitimate drift on the 16 toneGainLUT-family records (tone.* through
      the mask + zones.*) re-pinned from the proof lane's own drift printout.
- [x] Preview dither: `renderPreview` now runs the export's own `applyDither` before
      its 8-bit sRGB quantize — the loupe no longer shows banding in skies the
      exported file renders clean (checklist step 10 puts it in front of the owner)
- [x] Latency HUD behind a debug key (⌥⌘L): input→draft ms, draft ms @size,
      settle ms @size — the draft line's @size is the ladder's chosen rung
- [x] The rest of that bullet: os_signpost intervals around decode / plan /
      rasterize / render in `PipelineRenderer.renderPreview` (subsystem
      dev.lumenapp, category render — an Instruments trace of a laggy drag now
      says WHICH phase ate the budget), and the HUD grew two counter lines —
      `tables` and `rasters`, each hits/bakes/stale-serves since launch, read
      from `PlanTableCache.currentStats` and `MaskRasterCache.currentStats`.
      The tables line is M1a's fraud detector: a drag whose hit+stale share is
      not ~100% after its first frame is a cache key being defeated. Counter
      semantics pinned by a Linux test.
- [x] Last folder remembered across launches (security-scoped bookmark in
      UserDefaults, plain-bookmark fallback both directions, existence-checked;
      checklist step 1 verifies it on a real Mac)

**Owner session A:** drag every basic slider on a masked, denoised, sharpened real RAW —
nothing may change on release; Highlights/Whites/Blacks judged with the HUD visible
(settles MAC-04 with evidence); zoom stability; double-click reset.
**HELD 2026-08-26** (docs/sessions/01-results.md): MAC-04 **closed** — all six tone
controls owner-confirmed working; MAC-07 **root-caused** — the zoomed draw ratio never
normalized for proxy resolution (fixed, `LoupeGeometry.zoomedRatio` + tests);
double-click reset was genuinely broken (tap buried behind the drag; fixed). No
pop-on-release reported.
**Exit gate:** sliders feel immediate; no pop-on-release anywhere; MAC-04/MAC-07 closed
or precisely characterized. **ROOT-CAUSED 2026-08-27** after the owner re-reported it
as "goes by notches … changes in one frame instead of a slope": neither suspect was
it. The viewer cancelled its render task on every drag event and then DISCARDED any
completed frame whose task had been cancelled — checking cancellation after the
render had already run (RenderCoordinator's post-render stale(), PhotoRenderModel's
pre-apply guard). Events outpace drafts, so during continuous motion every finished
frame was rendered and thrown away, and the screen moved only at the hand's own
micro-pauses. No draft speed could fix that loop. `FrameDelivery` (LumenCore) now
holds the law — staleness belongs to STARTING work, never to finished work; a
completed frame is delivered under identity+order guards alone — and the drag-storm
simulation pins it: the old rule delivers 0 frames at 8 ms events / 30 ms renders,
the new one delivers at render cadence (~33/s). Next owner session verifies feel;
HUD numbers now measure the remaining ceiling (draft ms itself).

## M2 — The basics are right

Owner's framing after session A, now this milestone's charter: *"the difference
between us and Lightroom is less so the product, it's more so the accuracy — I want a
factual and testable area where this comes out as accurate as possible."* Accuracy
means, concretely and testably: (1) **calibrated** — each slider's value means what it
says, against a written physical contract per control (Exposure +1.00 multiplies
scene-linear luminance by exactly 2; Contrast leaves its pivot untouched at any
setting; Temp writes the Kelvin it shows; endpoints reach their documented targets);
(2) **smooth** — fine travel produces proportionally fine output steps, measured at
~200-step granularity, no plateaus-then-jumps (the owner's "switches little by
little"); (3) **competitive** — recorded side-by-sides against open implementations,
and against Lightroom via owner-exported references.

- [x] Tone-cube knot-density MEASURED (`AccuracyProbeTests`, 2048-point sweep, 7
      moves): the 32-knot cube tracks the 1024-sample table to mean ≤0.006 EV, but
      localized error peaks at **0.080 EV (Whites +100, scene +0.8 EV)** and
      0.065 EV (Blacks −100, scene −3.9 EV) — right where skies and deep shadows
      live. And `RenderGraph.applyTone` uses the SAME 32-knot cube on the export
      path.
- [x] Follow-up from that data, DONE with the numbers: `RenderPlan` now bakes its
      stored tone cube at the plan's own fidelity — export plans (lutSize ==
      exportSize) get the 65-knot cube, cutting the Whites +100 worst case 0.0797 →
      0.0258 EV (asserted at ≤0.040, watched failing both ways with the 32-bake
      substituted). Interactive STAYS 32, decided by measurement: a bake costs
      15.7 ms at 32³ / 53 ms at 48³ / 132 ms at 65³ (debug, x86) and it runs at
      plan init — during a drag, every mouse event. If the interactive 0.08 EV
      localized error ever shows on a real photo, the route is baking the finer
      cube stale-while-drag like the other tables, not paying 8x on the event path
- [x] Fine-travel smoothness probe (200 steps × 6 tone controls × 5 patch tones,
      sRGB-encoded): **no dead-then-jump quantization anywhere** — the engine's
      travel response is smooth, so session A's "switches little by little" points
      at frame delivery (the zoomed full-res drafts, since fixed), pending HUD
      numbers. Findings: Whites read as the least smooth control (max step 3.1×
      mean) — INVESTIGATED and acquitted: at 400-step granularity the response is
      smooth with zonalScale exactly 1.0 across the whole travel; the "jumps" are an
      end-loaded curve (the last 5 units deliver ~3× the mid-travel rate at a
      bright-mid tone) and the dead stretch is the negative shelf legitimately out
      of reach of a 0.72 patch. End-loading is a tuning question for the LR
      references, not a discontinuity;
      Contrast at mid-grey is EXACTLY zero across full travel (the pivot contract,
      confirmed); the zones are hard-partitioned (Highlights/Whites touch nothing
      ≤ mid-grey, Shadows/Blacks nothing ≥ it) — a design difference vs Lightroom's
      overlapping zones that the LR references will quantify
- [x] First calibration contract asserted: Exposure scales scene-linear light by
      exactly 2^slider (1e-9 relative, ±4 EV) — `testExposureIsCalibratedInStops`
- [x] Remaining calibration contracts DONE (AccuracyProbeTests): Contrast pivot
      invariance was already asserted through the full tabled pipeline; NEW — the
      Kelvin slider is anchored to the CIE STANDARD (6504 K lands on D65's published
      (0.3127, 0.3290), 5003 K on D50's, ±0.0015 xy; watched failing with a 2%
      kelvin mis-scale substituted), and the four range sliders' endpoints are
      asserted against the engine's documented constants through the full gain
      stage (H/S ±2.0 EV, Whites +1.3, Blacks −2.2; watched failing with Whites
      mis-wired to the H/S constant).
- [ ] Owner-exported Lightroom references (same RAW, one slider moved, exported
      TIFF/JPEG) for Exposure ±1/±2, Highlights/Shadows ±50/±100, Contrast ±50 —
      the direct answer to "is Lightroom more accurate"; blocked on the owner, rides
      the same ask as the RAW fixtures
- [x] Per-slider accuracy dossier (docs/24-slider-dossier-{tone,color,detail}.md):
      EVERY user-facing slider audited — expected math from ≥2 independent cited
      sources (Adobe docs, darktable/RawTherapee manuals, CIE/DNG/ASC standards,
      the original papers), implementation at HEAD with file:line, verdict, ranked
      gaps. Headlines: Exposure, Contrast+Pivot, Printer Lights (best-in-field),
      B&W, the Curve's domain/monotonicity, WB's core math, the denoise framework,
      grain and halation mechanisms all CORRECT against the cited consensus.
- [x] **Every-slider verification campaign** (owner, session B: "verify every
      slider … rigorous testing … actual output that is measurable and accurate"):
      docs/27 is the audit that makes "every" checkable. Coverage: 24 draggable,
      image-affecting sliders had NO proof record — Density (the "immovable"
      slider: gated by design at Saturation ≤ 0, now with a visible inline hint
      instead of a hover-only tooltip), Protect Skin, the entire 14-slider Colour
      Balance grid, mixer Uniformity, Halo Suppression, vignette, and five classic
      denoise sliders — all now registered (135 controls; the first claim here
      said 25/136 and recorded-before-the-recorder-finished, and the audit's own
      docs-honesty agent convicted it — counts corrected, records landed in the
      commit that carries this line).
      Calibration: SliderContractTests pins the per-control promises (−100
      Saturation reaches true B&W at every protection setting; Density densifies
      monotonically and cannot move a neutral; Vibrance's low-chroma weighting;
      protectSkin bites skin >40% and leaks <15% to blue; vignette −2 EV = corner
      at exactly 2^−2 on the Linear preset; curve points pass through themselves;
      grain exact-zero at 0 and variance-monotone; Hot Pixels at 100 halves the
      worst impulse). The campaign's biggest catch: the contract probe convicted
      Uniformity's convergence field — per-band full-deviation pulls cancelled at
      seams into BACKWARDS moves, wheel-wide convergence at 100 measured +0.1° on
      54° of pair spread; fixed (blended circular-mean target, monotone field, no
      anti-pockets) before the first record could pin the defect, with the
      remaining mid-band weakness recorded in docs/27 rather than asserted away.
      Dispositions with reasons for everything not Linux-measurable (capture
      sharpening, AI denoise amount, masks, geometry, export sliders) in docs/27
      §3.
      CLOSED GREEN: proof sweep #17 ran all 135 controls on CI — drift CLEAN,
      every floor and declared reversal held — and ci #226 plus GPU-parity #15
      are green on the same tree, so "every slider brings measurable, accurate
      output" is now a property CI re-proves on every sweep. Getting there
      surfaced two masked macOS compile errors (one per blind push: the
      ImageBuffer with no url, then the pick guard standing outside the actor)
      and taught the parity lane to watch everything it builds, not just what
      it tests.
- [x] **Six-agent audit** (owner, session B: "take a bunch of agents… find any
      issues… make sure everything's accurate"): six specialized agents swept the
      app (UI/UX, concurrency, engine math, pipeline caches, persistence, docs
      honesty) hunting more instances of this repo's proven bug classes. The two
      deepest finds were in the engine and are FIXED with watched-failing probes
      (the reversed AgX inset — its own commit tells the story — and the
      tone-cube/scale normalizer split). Fixed in the same batch, each verified
      against both sides: the crop tool missing from ViewerRenderKey; the mixer
      ring's buried double-click that edited the band instead of resetting; the
      compare pane's buried cursor double-click and its still-live zoom pump;
      Auto Tone / footer Reset / two modified-dots comparing against bare
      defaults instead of the photo's startingRecipe (the JPEG double-tone-map
      that survived undo); the eyedropper writing its solve into whichever photo
      was selected when it returned; the folder-scan window where one click plus
      one slider destroyed a saved recipe in both stores; the sidecar resolver
      blind to backward-moving mtimes (Time-Machine restores, synced sidecars —
      re-pinned in its test with the argument); the mask-raster cache serving
      photo A's selection for photo B after Paste Settings (file identity now in
      the key, invalidation wired); the soft-proof table poisoned by a stale
      draft under the settle's exact key; grain Reset landing on a different
      number than its own modified-test; the denoise masters' reset stamping the
      hand-set bit; the embedded preview painting over a completed draft; five
      smaller lifecycle holes (source-state save at quit, matte kind swallowed
      mid-pass, stale library facets, RawTruth under empty selection, WB Auto's
      hover-only explanation); and the honesty batch (BUILDING.md's "no one has
      run this on a Mac", README's session count, two disclosure notes restored
      to prominent, the mask-source "precisely this" comment now stating the
      measured divergence).
- [ ] **Audit fix queue** (verified findings deferred with reasons — full agent
      reports in the session log; items carry their sites):
      1. ~~CatalogStore.saveRecipe UPDATEs the working row in place~~ FIXED: a
         working row whose pipeline_version is newer than the recipe being saved
         is demoted to a named `version` row (byte-identical, visible in the
         edits list) and the save INSERTs a fresh working row; same-or-older
         rows still update in place. Both directions pinned in CatalogTests;
         watched failing with the guard disabled.
      2. ~~flushSidecars drops a failed/refused write permanently, and treats a
         non-UTF-8 sidecar as absent → wholesale replace~~ FIXED: failed writes
         re-queue (newest entry wins) and retry on a 15 s cadence;
         `XMPSidecar.classify` keeps `absent` and `unreadable` apart — including
         BOM-less UTF-16, which is byte-valid UTF-8 and needed an explicit NUL
         check — so an undecodable sidecar is left byte-untouched. Classification
         pinned in SidecarAndIngestTests, watched failing with unreadable
         collapsed back to absent. Refused merges (splicer returns nil) remain a
         deliberate permanent skip: the catalog holds the truth and the foreign
         file is preserved.
      3. ~~History coalescing keys carry no photo identity~~ FIXED: the folding
         rule moved to LumenCore as `HistoryCoalescing.shouldCoalesce` — same
         control AND the same photo set AND inside the window; equality on the
         photo set, so a step's `before` stays complete for everything it can
         restore. Six Linux tests; watched failing with the key+recency-only
         rule substituted back (photo-switch and selection-change cases both
         convict).
      4. ~~sliderGestureActive latches shut when SwiftUI drops .onEnded~~ FIXED:
         two unlatches — an 8 s silence watchdog (armed per gesture, measures
         silence not duration, retired on normal release) and the photo switch
         in primarySelection.didSet; the folder-switch flush now also retires
         the watchdog.
      5. ~~On-image drags bypass the slider-gesture deferral~~ FIXED: mask
         canvas (line/radial/brush), crop move + resize, histogram zones, curve
         points/splits, zones-panel pivots, wheels pivot strip and the mixer
         ring arcs all fire sliderGestureChanged. Straighten already wrote once
         at release and the before/after split writes no recipe — both left
         alone on purpose.
      6. ~~recipe.develop.raw.decoderVersion recorded, fingerprinted, never
         honored~~ FIXED: decode() resolves the recipe's recorded version against
         `supportedDecoderVersions` and honours it when this OS still ships it,
         falling back to the pinned-newest when it does not (a working newer
         decoder beats a dead recorded one — the same trade init's probe makes,
         now with a per-decode nil-output fallback too). The resolved version
         joins DecodeKey, so a v11 recipe and a v12 recipe can never share cached
         pixels in one session. Needs a RAW on a Mac to exercise; rides the
         fixtures ask.
      7. ~~A settle superseded by a sibling pane gives up while stale tables are
         on screen~~ FIXED: `PlanTableCache.anyBakePending` (the one public
         member; the working surface stays internal) and the settle loop's
         keep-the-draft early-out now refuses to stop while any table bake is
         outstanding.
      8. HDR shoulder-power floor breaks the slope-at-pivot contract with a C¹
         kink at mid-grey at EDR peaks (DisplayTransform.swift:211-212; needs a
         design decision, engine agent finding 3 has the numbers).
      9. ~~FilmLab's dormant grain hook; referenceColor's hardcoded rec2020
         luminance~~ FIXED: `applyWithGrain`/`negativeDensity` (zero callers,
         contrary contract) removed and docs/14 §5.7 now describes the shipped
         tap point — grain composites at the end of formation, in the FORMED
         picture's density domain; `referenceColor` takes the same `space`
         parameter as its twin `exactColor` and weighs the tone stage's
         luminance in it (exact-equality test in ColorScienceTests, watched
         failing with the rec2020 hardcode restored).
      10. Doc staleness batch — the prose half DONE: BUILDING.md's schema bullet
          re-audited against the code (PhotoQuery/keywords/stacks are wired now,
          the unwired list shrunk and corrected; `.version` rows exist since
          queue item 1); docs/04+15 pivot constants replaced with the derived
          values and docs/24-tone's #1 defect marked fixed; docs/05 gained the
          uniformity/variance as-built note (flat-neighbourhood kernel + the
          measured-mean wiring and its basis); docs/06 gained the clarity
          as-built note (single-band guided vs the reference local Laplacian,
          with the measured rim numbers); docs/24-color's colorBalance/proof-
          registry gaps closed against docs/27; docs/04+12 carry the owner's
          panel-order amendment. The 9pt floor batch landed with the app batch
          (LumenBadge was already at the floor; the three sub-9pt glyph
          stragglers in ContentView and ViewerOverlays are at 9 now). Still
          open, deliberately: the Keymap repeat comment (owner call).
      11. ~~Superseded folder scan still runs the abandoned folder's backfill~~
          FIXED at both ends: the launch is gated on the scan still being
          current (decided in the same MainActor hop as applyScan), and an
          in-flight pass checks a generation counter at every chunk boundary —
          claimed synchronously by the superseding call, so a pass already on
          the maintenance queue stops even though the new call's work is queued
          behind it.
      12. ~~Uniformity's honest cure~~ DONE: `PipelineRenderer.measuredBandMeanHues`
          (once per file, ~512 px neutral decode, cached and invalidated with the
          mattes) → `RenderPlan(bandMeanHues:)` → the engine AND the colour-grade
          table's cache key, on every rendering path including the reference
          fallback and both mask-stage taps. The key part is load-bearing: without
          it photo B would render with photo A's cached convergence field.
          Plan-level test in ColorScienceTests (measured-first build order convicts
          a hues-blind key); basis + limitation recorded in docs/27 §2.
      13. Out-of-gamut scene values (a negative working-space channel, reachable
          only by extreme pushes) cross the corrected inset onto the toe's steep
          region, a crease the finish tables track loosely — interactive worst
          0.297, export 0.138, measured and bounded at ci #222's conviction
          (EngineIntegrationTests/RobustnessTests carry the mechanism). The cure
          is gamut-mapping working-space negatives BEFORE the table domain,
          which changes the exact path too — its own batch, with records.
      14. ~~The histogram normalizes bin heights to the tallest spike~~ FIXED
          same day: the owner's +5 EV screenshot read "29.86% white" over a
          panel drawn almost empty — a third of the pixels in one bin scaling
          every other bin sub-pixel (measured 0.013 of panel height, watched
          failing). `Histogram.normalized` now scales against the
          99th-percentile occupied bin (ceiling-indexed so sparse histograms
          keep exact proportions); spikes saturate at the panel top, the
          Lightroom behaviour. HistogramDisplayTests pins spike, sparse and
          empty.
      15. haloSuppression misses the rim it exists to damp (found 2026-08-28 by
          the P6 sharpening measurement, pinned failing-forward in
          `testHaloSuppressionCurrentlyMissesTheRimItExistsToDamp`; full record
          docs/24-detail gap 3, docs/26 §6). Both paths gate the damp on the
          LOCAL usm magnitude, but a real edge's rim sits 2–3 px onto the bright
          plateau where usm has decayed below the 0.15 EV floor — full deflection
          dulls the mid-edge slope and reduces the rim by exactly nothing. Cure:
          damp against the local plateau (local-range clamp) in BOTH paths, with
          constants measured, then promote the pinned test to the contract claim.
- [ ] Dossier-driven fix queue (full detail in docs/24; ranked by daily impact):
      0. ~~Path-to-white DEFECT~~ FIXED (owner: "+1.80 EV does not seem like an
         exposed picture. It seems fake"): the display transform's ratio branch
         curved the norm and kept the ratios FOREVER, so at the hue-stable default
         no amount of overexposure could bleach a colour toward white — measured
         96% chroma retained at +5 EV (`testOverexposureBleachesTowardWhite`,
         watched failing at the shipped default). The pastel wash in the owner's
         screenshot is that number. Fix: hue preservation now ramps quadratically
         to per-channel across the shoulder (untouched at the pivot, fully
         per-channel at the white anchor), giving 0.553 → 0.214 → 0.036 → 0.001 →
         0.000 residual chroma at 0/+2/+3/+4/+5 EV — a slope to true white, with
         midtones still fully hue-stable. This is the same mechanism darktable's
         sigmoid ships 66% hue preservation to escape; ours escapes it structurally
         and keeps the midtone virtue. Zones proof re-pins are unaffected (neutral
         ramps are invariant under the hue blend: the inset matrix preserves greys).
      1. ~~Zones panel DEFECT~~ FIXED: `Zones.defaultPivots` is now DEFINED by the
         documented EVs (−4/−2/0/+2/+4) through the engine's own axis constants, so
         numbers and docs cannot drift apart; the lock was watched failing at the
         old constants (all five EVs named in the failure). Proof #6 confirmed the
         drift on exactly the zones.* family and re-pinned from its printout;
         PROOF-04 (Dark zone invisible) closed by measurement — Dark's authority
         went 4.74 → 75.52 of 255 code values, and the authority floors re-anchored
         at 70% of the new measurements (Light/Bright measure lower now because
         their zones moved INTO the display shoulder, which is the transform being
         honest, not the controls going dead). Contrast's mid-grey pivot contract
         also asserted through the full pipeline.
      2. Sharpen Radius in output pixels — preview judgment ≠ export (M3 item,
         now with the exact fix site named)
      3. Mixer band centres are geometric (29.23°+45°k), not perceptual — orange
         sits ~21° off, foliage lands in Yellow's core: the single largest LR
         muscle-memory break; fix or formally accept
      4. ~~Masked grade reads default zone pivots (COLOR-16); masked Sat/Vibrance
         inherit invisible defaults (COLOR-27)~~ BOTH CLOSED: the local stage
         inherits the global wheels' windows (`adoptingWindows(from:)`) and the
         global density/protectSkin (`ColorAdjust.local`), stated once in
         LumenCore and used by both paths — `LocalPlan` takes them as required
         parameters so a call site cannot silently revert either. Structural
         convictions in MaskingTests (global pivots must reach a masked grade;
         global Protect Skin 0 must let a masked Sat −100 reach skin). Untouched
         global panels render identically by construction.
      5. ~~Point Color's eyedropper samples post-S6~~ FIXED: `RenderGraph` split
         into `colorStageInput` (S3–S8) + `localStageInput` composing it — one
         implementation, so the tap and the render cannot drift — and the global
         Point Colour eyedropper stores `sampleColorStageInput`, the value
         `ColorEngine.apply` actually compares against. The post-S6 tap
         (`sampleWorking`) had exactly one caller and a false contract; it is
         removed rather than left as an attractive wrong answer.
      6. Dehaze GPU: sky guard missing on + branch, skyness on − branch (skies get
         more correction than the reference defines)
      7. ~~Denoise luminanceAnchors double-count~~ MEASURED, ACQUITTED: the sweep
         (`testTheISOAdaptiveLuminanceDefaultsLandNearTheirMeasuredOptimum`,
         ProofFrames.noisyLumaFrame at each ISO's own profile) puts the resolved
         defaults 0.0/0.2/1.1/0.6% off their travels' optima at ISO
         400/1600/6400/25600 — the optimum genuinely climbs with gain here
         (0→10→10→30), unlike chroma's flat field, so the anchors stand and the
         pin now re-proves them on every push. LUMAPROBE table prints in the
         lane log.
      8. Tint clamp unsurfaced (engine right, UI silent) + as-shot Kelvin/tint
         units unverifiable without RAW fixtures
      9. Capture sharpening: wire the dormant Richardson–Lucy or remove the dead
         Radius control (M3 decision, already listed)
      10. Texture one-band spectrum vs reference band-pass: now measured
          (TextureSpectrumProbeTests, TEXSPEC in gpu-parity runs; first data
          run #20 — feared finest-scale over-boost refuted, real divergence is
          a 24–26% under-delivery notched at 3/6 px, parity by 16 px; verdict
          recorded in docs/24-detail gap 2). Still open: proof-registry holes
          (color.density, protectSkin, mixer.uniformity, colorBalance.*);
          H-K and tuning constants unpinned
- [x] Owner decisions on the dossier's deliberate divergences (2026-08-26, in
      chat): KEEP the compressed saturation push ("we want something subtle very
      often, a saturation that doesn't really look like it's been edited" — the
      design IS the preference), KEEP the luminance-preserving curve default, KEEP
      pure-gain Exposure. Still open: hard tone-zone partition vs LR feathering —
      decided after the LR side-by-side exports exist.
- [ ] UI/IA round from the same session: Basic panel reordered Tone → Presence →
      WB → Colour (done); DevelopNote collapsed to a hover-ⓘ except honesty
      notices (done); double-click-on-track reset already fixed, owner saw an old
      build; design audit delivered (docs/25) — headline: the shipped chrome
      violated Law 7's 18-25% surround zone by an order of magnitude. OWNER CHOSE
      OPTION A (2026-08-26), with a high-fidelity HTML mockup of Option B published
      as an artifact for a later call; steps 1-2 (elevation ladder + type scale)
      landed at df57ab9, checkpoint 1 (the brighter chrome, one full session before
      judging) rides the next build; remaining A steps 3-9 in progress
- [x] First shipping-path golden that MOVES the six tone sliders through RenderGraph,
      preview + export scale: `ToneShippingGoldenTests` drives each slider
      individually through `RenderGraph.build` at both table sizes, asserting
      aliveness against the default render AND parity against the reference on the
      same plan. Parity bounds are declared smoke bounds on first landing
      (0.12 interactive / 0.06 export — the two known architectural error sources
      are stated in the file); per-slider worsts print as TONEGOLD lines in the
      gpu-parity log, to be tightened to measurements on the next pass.
- [x] Tint honesty, the engine half: `WhiteBalanceEngine.effectiveTint` surfaces the
      physics-bounded magenta exactly like `effectiveHighlights`; and the WB
      eyedropper is cheap again — `tintLimit(kelvin:)` is memoized by exact kelvin,
      so a `neutralizing` sweep runs ~140 bisections instead of ~3 000 (counter
      asserted in TintGuardTests, plus a cache-equals-bisection identity test).
      And the panel half landed with the app batch: an inline caption under Tint
      (the Density lesson's visible-hint form, never hover-only) appears exactly
      when the shown magenta exceeds `clampedTint` for the shown Kelvin, naming
      the bound and the value the render uses.
- [ ] Re-verify-then-fix at HEAD (the audit ledger is stale — verify first): TONE-01
      as-shot Kelvin · TONE-34 Auto highlight branch · COLOR-25 Protect Skin at
      Sat −100 · denoise Colour dead zone + ISO defaults incl. the unmeasured
      luminanceAnchors double-count · Sharpen Detail direction · PROOF-04
      zones.dark.ev invisibility · PROOF-03 Primaries purity clamp · double-click
      reset vs the track-jump
- [ ] Proof records at full panel travel for every Basic-list control; the 13 missing
      sliders recorded; P1 REACHES made mechanical (test fails when shippingReader
      file:line drifts)
- [x] P6 baselines vs darktable/RawTherapee for tone, S/H recovery, dehaze, sharpening
      — first recorded competitive evidence, per docs/20 tier rules
      *(2026-08-28: all four legs recorded in docs/26 — tone §1–3, S/H recovery §4,
      dehaze §5, sharpening §6 — via `crosscheck.py` extensions plus
      `FieldBaselineProbeTests` printing Lumen's TONEBASE/HAZEBASE/SHARPBASE columns
      on every Linux lane run so both sides stay re-measurable. The sharpening
      measurement also caught the haloSuppression rim-miss defect, queued below.
      Still owner-blocked: the Lightroom reference rows.)*

**Owner session B:** re-edit 5 previously-Lightroom-edited photos, basics only,
side-by-side exports. **Exit gate: owner prefers or ties Lumen on ≥4 of 5.**

### Session C requests (2026-08-28, owner live, same-day)

- [x] Build identity visible in-app: the Lumen menu carries "Build N · commit ·
      date" above Check for Updates (BuildStamp, pinned by BuildStampTests;
      `build-app.sh` stamps CI's run number, mirrored into CFBundleVersion).
- [x] Click-to-zoom REMOVED at the owner's request ("this strange zoom … I'd like
      to honestly remove it") — `ViewportClick` and its tests deleted with it; Space
      and Z still toggle via the keymap. Replaced by two continuous gestures through
      the same `setZoom` verb: trackpad pinch (MagnifyGesture) and the LR-style
      scrubby drag (press at fit, drag right = in, left = back). Arithmetic is
      `ContinuousZoom` in LumenCore — exponential travel, snap-to-fit, ladder clamp —
      with Linux-run tests; the drag decides pan-vs-scrub ONCE at its first event.
- [x] Camera/lens filter menus said "No camera has been read yet" forever on a
      freshly opened folder (owner's Sony a7 IV / Lumix GX85 report): the metadata
      backfill's completion refreshed the grid's ORDER but never the facet lists —
      `refreshLibrarySections()` now runs at the same moment. (If a camera still
      fails to appear after this, the next suspect is the file itself — capture one
      problem RAW as a fixture.)
- [x] Zoom round two, from the owner trying it ("it does work … but a lot of times
      it jumps, especially the first zoom in"; "when I zoom in, I can't zoom out";
      "bad quality for a few seconds and then the good quality version loads … and
      when I zoom out, same thing again"):
      1. THE FIRST-PINCH JUMP, root-caused and pinned. The viewer requests the
         VIEWPORT's pixels at fit and the CAP's (4096) when zoomed, so the
         denominator of `zoomLevel` changes the instant a gesture leaves fit — the
         starting ratio was computed against the fit-mode denominator and then
         multiplied under the zoomed one, drawing 4096 device px into a 1920 px
         viewport. Measured on the substituted defect: a 5% pinch grew the picture
         2.24×, and every pinch after it was continuous because by then both sides
         were the cap. `ContinuousZoom.fitZoom` / `.zoomedFullLongEdge` now express
         the fit zoom in the ZOOMED denomination from the start
         (`testTheFirstPinchDoesNotJump`, watched failing at 2.24).
      2. THE QUALITY CHURN on every zoom in AND out: crossing the fit boundary
         changes the render key, and the draft pass then REPLACED the settled frame
         with the ladder's coarse one. `PhotoRenderModel` now skips the draft (and
         its debounce) when only the RESOLUTION changed — same photo, same recipe,
         a settled frame already up — so a zoom only ever gains sharpness.
      3. Double-click returns to fit: the scrub only zooms while held and only from
         fit, so a gesture that ended zoomed had no pointer verb back. Inert at fit,
         deliberately, so it cannot become the click-to-zoom just removed.
      Residual, accepted and documented at `trueFitZoom`: on a CROPPED frame the
      settle delivers fewer pixels than the source extent predicts, so the drawn
      size corrects by that shortfall when the first zoomed settle lands.
- [x] **Slider smoothness round 1 — the owner's "very, very big thing".** "Every
      single slider is still going and updating little by little … that is for every
      slider in the app." Traced end to end over the SHARED drag path, not per
      slider. Two mechanisms found and fixed, one instrument added:
      1. **THE MID-DRAG SETTLE, the primary cause.** `PhotoRenderModel.load` had no
         idea a gesture was in flight — `sliderGestureActive` existed and had zero
         readers outside `AppState`. So 40 ms after every draft, on every micro-pause
         a human's drag is full of, the viewer started a FULL-RESOLUTION pass: a
         fresh decode at a different scale factor plus EXACT table bakes (a settle
         must never serve stale), on a serial render actor whose passes have no
         cancellation points. Every event behind it waited 100–300 ms for a lane that
         could not be given back, and the picture then jumped to wherever the hand
         had reached. Now: no settle while the hand is down, and `AppState.settleTick`
         — bumped in `flushSliderGesture`, so it inherits the release, the photo
         switch AND the 8 s watchdog — asks for it once, at rest. Held as arithmetic
         in `FrameDeliveryTests.testAMidDragSettleIsWhatMakesADragStep`: a deliberate
         10-event drag delivers 6 frames with mid-drag settles and 10 gated.
      2. **The tone gain cube was the one expensive bake outside `PlanTableCache`** —
         32³ = 32 768 samples rebuilt at plan init (every mouse event), invalidated
         by exactly the six tone sliders and the zones. Now cached like every other
         table, `anyBakePending` extended to cover it so the rest-must-be-exact
         contract still holds. `PlanTableCache.traffic(_:)` is new and load-bearing:
         the aggregate counters CANNOT see a table that never came through the cache,
         so the first version of this test passed against the defect.
      3. Two main-thread wins on the way: `maskOverlayAlpha` published nil-over-nil on
         every pixel-touching edit (now guarded), and `\.sliderGestureChanged` was a
         freshly allocated closure per body pass — a new environment identity that
         invalidated every slider, canvas and wheel in the tree (now stored on state).
      Prior art verified as genuinely engaged, not assumed: `FrameDelivery`,
      `DraftLadder`, `RefineBudget`, both stale-while-bake caches, and the
      `sliderGestureChanged` plumbing (which reaches every develop control via
      `LumenSlider`/`LumenColorWheel` themselves — confirmed by grep, one native
      `Slider` remains and it is the grid's thumbnail size).
- [ ] **Slider smoothness round 2 — what round 1 deliberately did not do.** Ranked,
      with the measurement each needs:
      1. `AppState` → `@Observable` (the 56-`@Published` re-body named in this
         document's diagnosis, still unfixed). Per event it publishes THREE times and
         re-bodies every view holding the environment object — plus `LumenApp`'s
         Scene body and the entire menu-command tree, because the `App` holds state as
         a `@StateObject`. Interim, independent, cheap: move the menu's reads behind
         their own small observable; delete the `historyObserver` forward once it is.
      2. The serial render actor's own ceiling: one frame per draft render, ~28 fps at
         the `DraftLadder` budget. Honest, and visible as steps under a moving hand.
         Past it is the Metal-layer viewport `LoupeView`'s header already claims
         exists and does not — a milestone, not a fix.
      3. `PipelineRenderer.maskSource` is uncached and rebuilds a 1024-px staging
         render per frame whenever any mask reads the picture; `requestedLongEdge`
         asks for a flat 4096 when zoomed rather than what is visible.
      4. `updateRecipe` builds two full `renderIdentity` projections per photo per
         event, on top of a deep compare it already did.

## M3 — The shipping path becomes the specced path

- [ ] Clarity: local Laplacian on the GPU; P5 parity at preview + export scale
- [ ] Resolution-scaled sharpening; export mask raster no longer a ≤1024px upscale
- [ ] Dehaze per-pixel sky guard on the GPU
- [ ] Texture third attempt, gated on the gradient-vs-edge probe (ramp = consistent
      orientation + near-zero second derivative); if ambiguous → demote to M6;
      re-apply the recorded negative-side window fix
- [ ] Vignette centring unified (crop-centred both paths; golden on a cropped frame)
- [ ] Capture sharpening: wire Richardson–Lucy with a test, or remove the dead control

**Owner session C:** presence + sharpen/denoise on real frames incl. skies; halo hunt.
**Exit gate:** no rims at defaults; export sharpening matches preview judgment.

## M4 — Culling at key-repeat speed + work survives

- [ ] Second-launch next-photo <50ms by the HUD; first grid <1s (registerAndLoad
      skeleton-first — today a per-file sidecar read gates the first grid)
- [ ] Rendered-preview cache produced (PreviewSource.lumen, fingerprint-keyed — today
      every photo select re-runs the full pipeline)
- [ ] Export off the interactive render actor (own lane; today batch export freezes
      the viewer; non-trivial — shared renderer + matte cache — scoped here on purpose)
- [ ] Work-survives set re-verified at HEAD: LIB-01 rename/move · LIB-08 sidecar
      freshness · OUT-15 silent stage drop · MASK-23 brush-blob race · export recipes
      out of UserDefaults into export_recipe · backup retention

**Owner session D:** cull a real card cold and warm; quit/relaunch/rename loses
nothing. **Exit gate: zero wait-for-preview moments.**

## M5 — The daily workflow completes

- [ ] LUT import: importer UI + look.lut stage on both paths + panel slot
- [ ] Vision mask orientation verified on the owner's Mac; mask drafts live during
      drag; mask local-slider proof records
- [ ] Export correctness: copyright/contact actually written (zero tests today),
      sizes, color spaces, HEIC fallback
- [ ] The FAKE sweep: every caption/tooltip vs behavior, once — hide or fix (incl.
      the stale doc-comment claims the audits flagged)
- [ ] Undo labels (everything reads "Edit" today)

**Owner session E:** one real shoot end-to-end without opening Lightroom.
**Exit gate: the owner ships photos from Lumen.**

## M6+ — Optional: darkroom edge + hardening

Film lab verified on Mac · 120Hz hitch-rate pass · Texture (if demoted) · Tier-2
denoise harness against a stub · scopes/compare polish · history panel · backlog
re-triaged by what the owner feels.

---

## Standing loops

1. Local Linux lane green BEFORE every push; full CI on push; never >3 unverified
   pipeline commits deep.
2. Per fix: reproduce → fix → watch the test fail with the defect substituted back →
   prove → record. A check that has never failed is not a check — and that now extends
   to CI wiring, with timing sanity (a "comparison" finishing in 0.084s is a fraud
   detector).
3. A control's status improves only when a proof is recorded, never when code is
   written (docs/20).
4. Milestone gate: CI green + proof lanes green + owner session passed. A failed
   checklist item keeps the milestone open.
5. Ship-to-self: every merge to main builds the app artifact.

## Definition of done — per Basic-list control

P1 REACHES (mechanical) · P2 ALIVE + P3 AUTHORITY (full travel, floors) · P4
WELL-BEHAVED (asserted) · P5 PARITY (preview AND export scale, in a lane that runs on
pipeline changes) · P6 BASELINE (open implementation or standard) · DRAFT-TRUE (visible
while dragging) · OWNER-SEEN (appeared in a passed session checklist).

## Owner session protocol

Build pulled from the CI artifact (with the `xattr -dr com.apple.quarantine` reminder
in every checklist). One committed checklist per session (docs/sessions/NN-checklist.md):
10–15 steps, each with "what to look at" and a blank "what I saw" line. Observations in
plain words; diagnosis happens repo-side. The HUD makes every session produce numbers.

## Risks

CI runner flakiness (#182) → local lane covers core, owner can re-run, batch macOS
pushes. GPU work unverifiable locally (Texture: two reverts) → gpu-parity per-push on
pipeline paths lands in M0 BEFORE M3. M1's full-pipeline-draft bet → de-risked by the
M0 probe; the ladder absorbs variance; the stale-while-drag mask cache is the fallback.
Schema changes lose data (MAC-01 class) → every recipe format change ships with a
tolerant-decode test against the previous format's sample sidecars. Owner availability
→ milestones sized so agent work never blocks on more than one session; M6+ absorbs
idle time.
