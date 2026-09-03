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
   — **No longer true, measured (M2 round 2).** `PlanTableCache.tableAllowingStale`
   closed this: on the DRAFT path plan construction is flat at ~3.5 ms across every
   control, including the ones that re-key a table on every event. Only the settle
   pays a bake, once per gesture, which is what makes the picture at rest exact.
   `PlanCostProbeTests` prints both paths on the free lane and fails if the gap ever
   closes.
3. **Main-thread waste per mouse event** — the one that survived three rounds and, on
   the evidence of M2 round 2, is the likeliest cause of "every slider ticks": one
   ObservableObject with 56 @Published re-bodies every view per event; FilterBar does 14 full `allPhotos` scans per body
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
      judging) rides the next build; remaining A steps 3-9 in progress.
      SUPERSEDED 2026-08-29 by the full refresh below — docs/25 now carries a status
      header mapping each of its nine steps to where it went.
- [ ] **Full UI/UX refresh (docs/28), commissioned 2026-08-28**: "the ui ux is rough…
      I genuinely don't get some of it… make it better than lightroom in terms of ui
      as well now." Seven phases; this is the live ledger, docs/28 Part 6 is the plan.
      **Phase 1 — legibility and density (no IA change):**
      - [x] labels stop truncating: `labelWidth` 78 → 94, track 158 → 142, the
            `SliderDragTests` fixture re-proven parametrically 100-400 pt (9b8df2b)
      - [x] `DevelopDisclosure` stores `() -> Content`, so closed means closed —
            invisible today, and the precondition for Phase 4's accordions (9b8df2b)
      - [x] 33 always-visible prose blocks collapse to the ⓘ row across Colour, Look
            and Masks; 6 stay `prominent` (3 honesty disclosures, 3 live geometry
            readouts) (88a2f99)
      - [x] section rhythm moves into `LumenSectionHeader.topRhythm`, which retires
            13 hairlines (10 inter-section + the develop column's 3 band fences, now
            a `windowBase` 0.18 step); 2 intra-section rules deliberately survive.
            Hover-only Reset shipped — OWNER TASTE CALL, one line to revert
      - [x] footer verbs borderless at rest (the half of docs/25 step 6 that a80673c
            commented but did not implement)
      **Phase 2 — colour where colour is information ⚑ (the owner's headline ask):**
      - [x] Law 7 amended explicitly in docs/00 per §3: a track may carry chroma iff the
            control's axis IS a colour direction, at no larger a scale than the 4 pt
            groove. Every tonal control stays neutral — including the exposure ramp the
            owner named, which is Part 7 item 1 and still his to overrule
      - [x] `LumenTrackStop` anchors stops to VALUES, placed by the same `fraction(of:)`
            that draws the thumb — so Temp's neutral lands at 0.663 of the mired track
            and not at its midpoint. Three Linux tests pin it
      - [x] eleven coloured tracks: Temp, Tint, the mixer's Hue/Saturation/Luminance per
            selected band (neutral again in All bands, because the track states scope),
            and the lightness bar under each of the four grading wheels
      - [x] fixed on the way: an untitled `LumenSlider` reserved the full 94 pt label
            column, so the wheels' 108 pt lightness bar asked 158 pt of layout and drew
            no visible track at all
      **Phase 3 — reclaim the chrome ⚑ (the owner's first-named complaint):**
      - [x] the filter bar's two full-width rows of fourteen controls become ONE row of
            five: search, a Filter button badged with the active CRITERIA count, a
            Clear that appears only when something is filtered, then sort, direction,
            auto-advance and thumbnail size
      - [x] criteria move into a popover where they finally have room for per-chip
            counts under every star and every label swatch (Capture One's best idea)
      - [x] the query sentence and the photo count move to the status bar, off
            `LibraryFilter.sentence` so the popover and the status bar cannot describe
            the same query two different ways
      - [x] Clear stayed OUT of the popover: it carries ⌘\, and a `.keyboardShortcut`
            on a view not in the hierarchy is never registered — it would have stayed
            in the source, still passed `KeyGrammarTests` (which reads shortcuts as
            text), and been dead in the app
      - [x] sidebar's five unrelated jobs become four collapsible sections on the SAME
            `LumenSectionHeader` the panels use — Library, Albums, Keywords, Stack.
            Expansion in `@AppStorage`, never published on AppState. Keywords and Stack
            start closed (both inert until something is selected); a closed section
            holding state wears the accent dot, which is docs/12 §12.12's hidden-panel
            indicator arriving by another name
      - [x] the culling counts became CONTROLS: "Picked 14" now shows the picks, which
            is what a count in a source list means everywhere else in the field
      - [x] near-miss caught: ⌘B, ⌘K and ⌘G were about to end up inside collapsible
            sections — the same dead-shortcut defect as ⌘\, one commit later, by a
            different door. Every shortcut-bearing button now sits ABOVE the fold.
            RULE FOR PHASE 4: a section that folds may not be the only home of a
            keyboard shortcut
      - [x] docs/25 steps 7 and 9 complete (accent selection + 10 pt stars landed in
            a80673c; sidebar rows here)
      - [x] hover rating on grid thumbnails: five stars appear under the pointer and
            each is a target. `PhotoCell` stays value-typed — the click arrives as
            `AppState.ratingSink`, stored on the same `lazy var` pattern as
            `sliderGestureSink` so it is one closure identity rather than sixty per
            body pass. The click SELECTS then rates, because `setRating` acts on
            `editTargets` and would otherwise rate whatever was selected elsewhere.
            Filmstrip cells are excluded (96 pt is too small for five targets).
            WATCH: this is the per-cell `.onHover` docs/28 §5.5 called an unmeasured
            macOS 15 scrolling cost — one owner session settles it, and the
            container-level `onContinuousHover` fallback is written down there
      **Phase 5 — one home for colour ⚑ (items 18-19 only; 17 needs the workspaces):**
      - [x] four cramped 68 pt grading wheels become ONE 150 pt wheel under a
            Shadows/Midtones/Highlights/Global segmented control. `LumenSegmented`
            gained `marked`, so each zone holding a grade wears the accent dot and
            one-at-a-time does not cost the at-a-glance "what did I change?"
      - [x] picker-first mixer: `ColorEngine.dominantBand` in LumenCore (11 Linux
            tests) answers which band owns a sampled colour, as the argmax of the same
            membership vector the pixel loop uses — so a widened Blue claims the hues
            it actually grades, and a near-grey returns nil instead of a random band.
            New `PickTarget.mixerBand`; the eyedropper is the mixer's first control
      - [x] cost accepted and written down: `selectedBand`/`allBands` moved from
            ColorPanel `@State` to AppState (the pick resolves on the render actor and
            must write where the panel sees it), so a band CLICK now publishes
      - [x] item 17, Colour and Grading adjacent — DELIVERED BY PHASE 4 rather than
            by a change of its own. The complaint was "going through functionality
            for the grading like the colours and stuff is hard to understand", and
            its cause was that Colour and Look were two of eight tabs with five
            others between them. In Grade they are `canonicalRank` 9 and 10, one
            scroll apart in one column. There is nothing further to move; inventing
            a change to close the item would be motion rather than work
      **Phase 6 — speed (items 20 and 22 of six):**
      - [x] arithmetic typed entry, `SliderEntry` in LumenCore (19 Linux tests):
            `+= 0.3`, `-= 0.2`, `* 2`, `/ 2`, and a bare number stays ABSOLUTE
            including a negative one. Figma's leading-minus-is-relative grammar was
            rejected on purpose: the readout pre-fills and selects, so replacing it
            with "-40" is how you set −40 on a ±100 control, and Figma's rule would
            make that a silent −10. Also refuses nan/inf/1e999/hex//0 and an
            overflowing RESULT from finite inputs
      - [x] ⇧ fine-drag, `FineDrag` in LumenCore (14 Linux tests). An anchor that
            moves only when the modifier does, so the thumb never jumps at the gear
            change. AND `resolving` returns a replacement only when the gear actually
            moved — a `@State` write is a view invalidation, so storing a gearbox per
            mouse event would have published on every drag event and quietly undone
            the drag-smoothness work this session started with
      - [ ] ⚑ BLOCKER for item 24 (⌘K control palette): ⌘K is already "Keyword the
            selection". Belongs to item 30's one deliberate keymap pass, not to
            whoever builds the palette first
      - [x] item 23, scrub the number: the readout is a SECOND, FINER track — 426 pt
            of travel per full range against the column's ~142, so it is ~3x finer than
            the track and ~12x with ⇧. Reuses `FineDrag` and the control's own scale, so
            scrubbing Temp still moves in mireds. `minimumDistance: 3` keeps
            tap-to-type alive. 426 is PICKED, not measured — one constant if wrong
      - [x] item 21, a tick at the default: `SliderDrag.crossesDetent` (7 Linux tests)
            is a CROSSING test, not proximity — "near the default" is true for many
            samples of a slow drag and would rumble instead of marking a landmark.
            Detent is `defaultValue`, so on Temp/Tint it marks the PHOTO's as-shot
            neutral. Silent on a mouse: only Force Touch trackpads perform
      - [ ] items 25, 26: Speed Edit (D44), ⌥-scroll
      **Phase 7 — focus and the keyboard nudge (items 27-29; 30 is yours):**
      - [x] focus ring drawn rather than the system's: macOS's blue halo is sized for
            standard AppKit controls and reads as a bug on a 4 pt groove.
            `LumenFocus.swift` is a LEAF on purpose — `.focusable`,
            `.focusEffectDisabled` and `KeyPress` are all new here and this machine
            cannot compile LumenApp. The surface checker caught `KeyPress`
            unregistered, its second catch this phase
      - [x] `sliderHoldsFocus` on AppState: NOT `@Published` (nothing renders from it;
            only the dispatcher reads it at key-down) and a COUNT rather than a flag,
            because SwiftUI does not order focus changes and moving between two rows
            can deliver the new `true` before the old `false`
      - [x] ←/→ nudge one step, ⇧ ten. `SliderTrack.nudged` in LumenCore, 11 Linux
            tests: clamps to the SOFT range like a drag, always lands on the step, and
            on Temp moves 10 K at both ends because a press is denominated in steps
      - [x] found while writing it: the dispatcher's Escape branch would have eaten the
            key before the slider saw it, making `onKeyPress(.escape)` unreachable and
            "focus is releasable" false. Both yields reuse the zoomed-loupe mechanism
      - [x] key repeat deliberately NOT claimed — `onKeyPress` defaults to `.down`, so
            holding an arrow nudges once. Keeps the gesture bracket prompt.
            Hold-to-sweep needs `phases: [.down, .repeat]` AND dropping the bracket for
            the 8 s watchdog, which is a longer crash window — an owner call
      - [ ] ⚑ item 30, THE KEYMAP RECONCILIATION — AUDITED AND WRITTEN UP as
            docs/29-keymap-reconciliation.md, awaiting the owner's answers. Eight
            bindings have drifted from docs/12's canonical map; five would move under
            the recommendations. Two live collisions: workspaces want `1`-`4` (those
            are ratings — recommend `⌘1`-`⌘4`) and the ⌘K palette wants ⌘K (recommend
            keywording moves to `⌘⇧K`). Speed Edit turns out NOT to be blocked: docs/12
            §12.4 shares letters by tap-vs-hold on purpose, so it needs the
            discriminator built, not keys assigned
      **Phase 6 — speed (items 20-26 all landed or scoped):**
      - [x] item 24, the ⌘K palette. `ControlIndex` in LumenCore — catalogue plus
            ranking, 12 tests. Match strength sorts first (exact ▸ prefix ▸
            word-prefix ▸ substring ▸ subsequence) and the panel's canonical order
            breaks ties; aliases carry what people type (`temp`, `nr`, `bw`, `wb`).
            SCOPE STATED: it opens the section, promoting the Simple register via
            `reveal`; it does NOT yet focus the individual row, which needs every
            slider to carry a scroll identity — a change to every panel, not to the
            palette. Each result names its destination, so the palette also teaches
            the four workspaces
      - [x] item 30's second half: keywording to ⌘⇧K in all three places — modifier,
            `KeyGrammar` row, and the caption, which is the half that gets forgotten
            and the half that becomes a promise of a dead key
      - [x] item 25's RULES, wiring deliberately held. `SpeedEdit` in LumenCore:
            docs/12 §12.4's eight letters, the tap/hold discriminator, the drag
            arithmetic, 14 tests. Wiring changes when eight EXISTING keys fire — `S`
            is Scopes and `H` is Histogram, and a tap must toggle while a hold edits,
            so their action moves from key-down to key-up. Get it wrong and eight
            working keys stop working, and no amount of reading verifies a
            discriminator. Same split item 12 used
      - [ ] item 25's wiring — needs a session that can watch a real key behave

      **Phase 4 — workspaces and accordions (SHIPPED, items 12-16):**
      - [x] item 12, the `Workspace` model in LumenCore, 48 Linux tests: four
            workspaces, docs/12 §12.1's canonical order carried as `canonicalRank`
            with its gaps intact, the Simple/Full register, the hidden-active count
            behind §12.12's indicator, and the solo transition. Membership derives
            from one total switch, so there is no second table to drift; one test
            reads docs/28 §5.1's table out of the document and compares it
      - [x] Masks modelled by ABSENCE — no section case, a flag on `WorkspaceLayout`
            that every workspace switch leaves alone, which is docs/12:108's
            "floating/docked via a key, available in any workspace"
      - [x] no keys assigned: `1`-`4` for the workspaces collides with the rating
            grammar, and that is item 30's pass, not this one's
      - [x] SOLO INVERTED, on owner feedback minutes after the build went up: "can we
            make it so that I can open all of the chevrons at the same time instead of
            having to only open one at a time." A plain click now toggles only what it
            names and ⌥ solos. Lightroom does the same — Solo Mode is opt-in there.
            `SectionExpansion` expressed both all along, so this changed a default and
            not a rule; the opening state became every Simple section of Develop, which
            was one only because under solo a second open section was unreachable
      - [x] items 13-16, the UI half. The gate opened: the owner verified the drag
            on the round-5 build ("this is a whole lot better ... it's pretty
            solid"), and answered item 30's keymap question in the same breath.
      - [x] `PanelLayout` — the observable the plan named in three places and never
            had. Holds `WorkspaceLayout`; every verb through one equality-guarded
            commit, because `@Published` checks nothing and each verb recomputes a
            whole value including a set. Eight counting tests: a switch is one
            publish, switching to where you already are is zero, a 48-event drag is
            ZERO. `activeSection` and `PanelSection` are deleted, not deprecated
      - [x] the COLUMN owns the section header — title, dot and Reset. It had to: a
            section assembled from several panels (Optics from Crop and Lens) had no
            single Reset, and one folded into a disclosure lost the one it had, which
            is what silently happened to Denoise and Zones. `WorkspaceSection.reset`
            sits in LumenCore beside `nonDefault` with the property test that matters
            — reset a section and its dot goes out, and NO OTHER section's does
      - [x] the dot is ISO-aware for Detail: a high-ISO frame arrives with denoise
            already on, so comparing against `Denoise()` would light it on every RAW
            file ever opened, and a dot that is always on says nothing
      - [x] panels take `only:`, so the split ones stay single files; five whose own
            header repeated the column's render bare, the rest drop to `topRhythm: 8`
      - [x] four panels stopped owning a `ScrollView` — nested in the accordion's own
            they are traps, and Look is most of the column
      - [x] ⌘1-⌘4 in a `CommandMenu`, written out literally: `KeyGrammarTests` scans
            for shortcuts as TEXT, so a computed `KeyEquivalent` would have opted
            them out of the one check that catches a dead key. They cannot go through
            `KeyDispatcher` (it returns early on any ⌘ key) and could not live in the
            switcher, because Cull draws no column — the key that RETURNS from Cull
            would have been the one key Cull could not press
      - [ ] KNOWN STALE, not worth a fixture churn: four `ProofRegistry` records tag
            `panel: "Colour"` for saturation/vibrance, whose header now reads
            "Saturation" under Presence. `ProofRecord.panel` is descriptive metadata
            asserted by nothing, and is already loose (`tone.exposure` says "Basic")
      - [ ] SUPERSEDED — the old gating note, kept because the reasoning still holds
            for the next phase that changes per-event scope: they change how
            many slider rows are in scope per mouse event, so starting them before
            that verification makes a regression there and a regression here
            indistinguishable.
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
- [x] **Slider smoothness round 2 — measured this time.** Owner, third report on the
      same thing: "it's still not smooth … one by one, like tick by tick." Round 1 and
      the rounds before it fixed real defects that were not the cause. What is
      different here is that the guessing stopped: the instruments were built first,
      and they both convicted and acquitted.
      1. **THE DRAFT LADDER HAD NEVER SIZED A SINGLE FRAME.** `DraftLadder.record`
         refused any frame whose long edge was not exactly `rungs[rung]` (2048), and
         at fit the loupe never asks for 2048: `PhotoRenderModel.load` requests
         `max(1024, fullLongEdge/2)`, and `fullLongEdge` is the viewport in device
         pixels bucketed to 256 — ≈1280 on a 16-inch MacBook Pro, ≈1728 on a 5K panel.
         The guard fired on every frame of every drag at fit; the rung never moved for
         the life of the process. Frames could cost 300 ms and the one mechanism whose
         job is the 35 ms budget would not notice. It looked right because every test
         fed `requested: 4096` — the size the app asks for only when ZOOMED, which is
         the one place a drag does not happen. Fixed: heat steps down from ANY size
         (cost is monotone in pixels), targeting the first rung strictly BELOW the
         size just measured — stepping one index does nothing when the request is the
         binding constraint. Cheapness still requires a frame rendered at the rung.
      2. **THE WINDOW AND THE MENU BAR WERE REBUILT TWICE PER MOUSE EVENT.**
         `updateRecipe` published the recipe write AND, through a
         `history.objectWillChange` → `AppState` forward, the coalescing write into
         the open undo step. `AppState` is a `@StateObject` on `LumenApp`, so each
         publish rebuilt the `Scene` — all seven `.commands` menus — plus the
         filmstrip's `ForEach` over the whole folder, the grid, the sidebar, the
         filter bar and the status bar, none of which show an edit. The consequence is
         worse than waste: once a whole-window pass no longer fits between two
         mouse-moved events, AppKit COALESCES the undelivered ones and the app stops
         SEEING positions — so the thumb, the number and the picture step together, on
         every slider at once, which is exactly the shape of the report. Fixed:
         `CommandState` (the five facts the menu bar and develop footer display,
         equality-guarded) and `EditRevision` (the invalidation the twelve edit-facing
         views need); `AppState.recipes` is no longer `@Published`. A drag event now
         publishes on `EditRevision` alone. `DragBroadcastTests` counts the publishes —
         and earned its keep immediately: the first version of the replacement hung
         both signals off `didSet`, which fires BETWEEN the two halves of a mutation.
         `steps` and `position` are one value in two properties (`canUndo` is
         `position > 0`; `undoLabel` subscripts `steps[position - 1]`), so the Edit menu
         flickered a Redo item that never existed at three publishes per drag instead
         of one — the count the test caught — and `clear()`, which empties `steps`
         before zeroing `position`, subscripted an empty array: an out-of-range CRASH
         on the first folder switch after any edit. `HistoryStack.atomically` fixes
         both and a second test reads the labels from inside the callback, where an
         inconsistent stack traps rather than merely lying. The old
         `objectWillChange` forward never met either failure because SwiftUI coalesces
         invalidations to the end of the runloop turn; a direct callback does not, so
         the atomicity has to be real.
      3. **THREE EXPENSIVE FIXES RULED OUT BY MEASUREMENT** — the point of building
         the instruments. `DragProbeTests` (macOS lane) prices a 48-event drag with a
         fresh plan per frame; `PlanCostProbeTests` (free Linux lane) prices the CPU
         half. Findings, all at 1280 px:
         · **Materializing the decode and removing the readback: NOT RESOLVABLE on this
           runner, and neither is the lever.** Called "no difference" from the settle
           path, then "a ~10% win" from one draft-path run, and the next run reversed
           the ordering (lazy+iosurface 44.1 against materialized+iosurface 47.0). The
           reason is the runner's noise floor, which the probe now states in its own
           header: the SAME measurement — Exposure, draft, 1280 px — appears three
           times in one run's output at 64.4, 47.9 and 50.5 ms, a 34% spread on an
           identical configuration. Every row-vs-row difference claimed above was
           inside that. `cacheIntermediates` is already on, and the probe's source is a
           two-filter chain rather than a 45 MP demosaic, so a real decode may still be
           worth something — but nothing here measures it, and the claim that it did
           was mine to withdraw.
         · **The GPU→CPU readback inside the RENDER: no measurable difference**
           (`createCGImage` 48.2 vs IOSurface 47.6 ms). But this ruled out less than it
           was written to claim, and the scope error is worth naming because it nearly
           retired the strongest remaining candidate. `DragProbeTests` stops at
           `createCGImage`. It never touches what happens NEXT: the ~4.4 MB CGImage
           (1280×853 RGBA8) is handed to SwiftUI as a fresh `Image(decorative:)` on
           every frame, which becomes layer contents and a texture upload, on the main
           actor, and SwiftUI's `Image` is not a thin wrapper over `layer.contents`.
           NOTHING in this repository has measured the display path. So what is
           actually ruled out is "the readback inside the render is expensive"; the
           Metal-layer viewport — which replaces the display path, not the readback —
           remains untested and is now the leading unmeasured suspect if the owner's
           reading says the render is not the ceiling. The rung fix helps here too and
           for free: a 768 px draft is 1.5 MB to upload rather than 4.4.
         · **Plan construction on the DRAFT path is ~1 ms, flat across every control**
           — release Linux, `PlanCostProbeTests`: exposure 1.05, whites 1.75,
           saturation 1.13, texture 1.14 ms p50. Stale-while-bake is doing its job.
           Only the SETTLE pays a bake — whites 17.2, saturation 16.9 ms, against
           texture's 1.1 — once per gesture, which is what makes the picture at rest
           exact. (Debug is ≈10× throughout: 3.5 draft, 400 settle. The probe now
           prints its build mode, because the first reading of these numbers was a
           debug settle mistaken for a shipping draft — a 300× error.) The CPU half of
           a drag frame is therefore not the problem, which leaves the GPU graph and
           the main actor, and the graph at 1280 px is ~20-30 ms on a CI VM — enough
           for 30-60 fps, not for "tick by tick".
         · **Pixels keep buying frames all the way down — the opposite of what this
           entry said on its first draft, and the ONE row-comparison that survives the
           noise, because it is a monotone sweep rather than two adjacent rows.** The
           flat-below-1024 curve (1728 → 65.5, 1280 → 37.6, 1024 → 32.4, 768 → 31.8,
           576 → 28.7) was the SETTLE path, where a table bake sits under every frame
           as a fixed floor. On the draft path, which is what a drag runs, two
           independent runs both fall monotonically across all five rungs: 80.7 → 61.9
           → 52.6 → 37.3 → 34.8, and 64.2 → 47.9 → 45.2 → 38.7 → 37.4. Total 1728 → 576
           of 2.32× and 1.72×. Five points moving together twice is not the runner's
           noise; the cheap rungs earn their place. Corrected here rather than quietly
           edited, because "measure, don't reason" is this round's whole claim and the
           first reading of these numbers was still the wrong render pass.
      4. **The probe's own first row was wrong, twice, and both times it was read
         before it was doubted.** Core Image compiles each kernel on first evaluation,
         so the graph's whole compile cost lands once per PROCESS, on whichever row is
         measured first — dropping the first event of each drag does not touch it.
         Exposure read 63.3 ms p50 against Whites' 27.9, Saturation's 25.0 and
         Sharpen's 22.5, which says "Exposure is the expensive control" and is exactly
         backwards: it re-keys the fewest tables of the five. `warmUp` now runs
         throwaway frames per size before anything is timed — and it did NOT fix the
         row, which is the more useful finding: Exposure still read 64.4 with warm-up
         in place, and the same measurement elsewhere in the same run read 47.9 and
         50.5. The per-control table simply does not resolve on this runner. The
         warm-up stays (a first row paying the process's kernel compilation is still
         wrong), and the header now says which comparisons the output can support: a
         monotone sweep, yes; two adjacent rows under ~40%, no.
      5. **The instrument that should have caught all of this measures the opposite.**
         `PerfProbeTests` takes the BEST of four renders of the SAME plan over the SAME
         source with no decode. On the same runner and the same commit it reported
         20.0 ms at 1024 where the drag probe measured a 1280 px Exposure frame at 51.2
         and a Whites settle at 385.3. Kept — it is a useful graph-cost table — but it
         is no longer read as what a drag costs.
      6. **Every draft frame at fit was drawn BLOCKY, and the ladder fix made it
         several times worse.** Found by tracing the display path rather than by a
         probe. `plate` chose `ratio >= 1 ? .none : .high` — nearest-neighbour whenever
         the drawn ratio was at or above 1, "so a 1:1 inspection shows the pixels that
         exist". That is right about a 1:1 inspection and wrong about everything else,
         because at fit the ratio is ALSO above 1 whenever the proxy is smaller than
         the viewport, which is every draft there is. In a 16-inch MacBook Pro's centre
         pane (1180 pt, 2360 device px) a 1280 px draft is magnified 1.84× unsmoothed —
         and the new cheap rungs magnify 3.07× at 768 and 4.10× at 576. A smaller draft
         is supposed to cost SHARPNESS, which reads as the picture resolving; drawn
         like this it costs hard aliased edges that shimmer frame to frame, which reads
         as the picture flickering. `ProxyResampling.mode` (LumenCore, six tests,
         watched failing at all four magnifications) discriminates on what it should
         have all along: whether the pixels on screen are really the photograph's —
         zoomed to 1:1 or beyond AND showing the full-resolution frame — rather than on
         the drawn ratio. Magnifying a proxy is `.low`, not `.high`, deliberately: this
         sits on the per-frame display path and a 4× high-quality upscale per frame
         would spend the budget the smaller draft was sent to save.
      7. **The release stopped paying for a frame nobody waits for.** A release bumps
         `settleTick` and moves nothing else — `onEnded` commits the value the last
         motion event already committed — so the viewer rendered a draft that produced
         the picture already on screen, waited out the 40 ms debounce, and only then
         began the settle: ~70 ms of a 200 ms budget, at the one moment the
         photographer IS waiting for sharpness. `FrameDelivery.needsDraft` now skips
         both. Gated on the TICK, not on "the recipe is unchanged": a matte landing, a
         brush blob loading, ⇧S and a window resize all leave the recipe untouched
         while changing the picture, and each must still get its fast draft. Five tests,
         including that guard.
      8. **The HUD gained the pair that ends the argument**: input events SEEN per
         second beside frames DELIVERED per second (`EventRate`, LumenCore, tested).
         Latency alone cannot tell a render that cannot keep up (in 90/s, out 8/s)
         from input being dropped before the app ever sees it (in 10/s, out 10/s), and
         the two want opposite fixes. Three rounds have been argued without it.
- [x] **Round 3 — the flicker, and it was round 1's own fix.** Owner on the round-2
      build: "the knotching is gone which is great" — the ladder and the broadcast
      fixes landed — "but there was some flickering when I was moving stuff like
      contrast and blacks plus some others."
      That set is the diagnosis. `RenderPlan` bakes the tone gain cube as
      `gain / peak` and `RenderGraph.applyTone` multiplies `plan.toneGainScale` back;
      the comment where it is baked says the two "are meaningless except as a pair".
      Round 1 put the cube through `PlanTableCache.tableAllowingStale` to get it off
      the per-frame path — and `tableAllowingStale` returns, by design, the NEWEST
      table in the slot when this event's key misses, which every event of a tone drag
      does. `toneGainScale` is not cached; it is recomputed from this event's
      `toneGainLUT`. So every draft frame computed `oldGain(v)/oldPeak × newPeak`
      instead of `newGain(v)` — the whole picture wrong by `newPeak/oldPeak`, snapping
      back whenever a background bake landed. Measured on a Blacks drag: the shadows
      applied a gain of 0.94 where the table said 1.48, a 58% error, and the applied
      value was IDENTICAL across blacks 10/20/30 because the same stale cube was served
      each time. Worst on Contrast and Blacks because those move the peak gain most;
      present on Whites, Shadows, Highlights and the zones — "plus some others".
      Fixed by taking the tone cube off the stale path. It is the cheapest table here
      by a wide margin, and the cost is now measured rather than assumed: a tone draft
      goes from ~1.0 ms to 1.3–1.5 ms (`PlanCostProbeTests`, release), while a Whites
      draft stays at 1.48 ms rather than the settle's 17.69, because the expensive
      finish table keeps its stale-serve. Round 1 had cached it against a DEBUG-scale
      cost (~14 ms) that is ~0.4 ms in the build that ships.
      `testTheToneCubeAndItsScaleStayAPairOnTheDRAFTPath` holds it, watched failing at
      every step of a Blacks sweep. Its sibling did not catch this because it built its
      plan with the default `allowStaleTables: false` — only ever exercising the path a
      drag does not take, the same blind spot as the draft ladder's tests.
- [x] **Round 3b — the blur under the hand, which was a guess from before the ladder
      worked.** Owner: "when I press and hold any of the sliders I get a blurry picture
      while I'm sliding it, and only when I let it go it turns clear."
      That is the two-tier refine behaving as designed, and the design was making a
      decision it no longer needs to make. `PhotoRenderModel.load` asked for
      `max(draftLongEdge, fullLongEdge / 2)` — the draft capped at HALF the settle's
      resolution, on every machine, forever, whatever it could afford. Reasonable when
      nothing measured a frame; not reasonable once `DraftLadder` measures every one
      and steps down within a single hot frame. The halving is gone: the draft asks for
      the settle's own resolution and the ladder takes back exactly what this machine
      needs — none of it on one with headroom, so the drag is simply sharp.
      Two changes go with it, both necessary rather than incidental:
      · The ladder's top rung is 4096 (`LoupeView.maxRenderLongEdge`), so the top caps
        nothing. A ladder whose top rung is below the request can never answer "as good
        as what you asked for", which is what the top of a ladder should mean. The
        rungs in between are closer together so one hot frame gives back a sensible
        amount rather than half the picture.
      · The ladder is MONOTONE DOWNWARD while a hand is down (`allowStepUp`). Giving
        resolution back mid-drag is the machine keeping up; earning it back mid-drag
        spends frame rate on detail a moving eye cannot resolve, and at a rung boundary
        it oscillates — the picture's sharpness changing several times a second under
        the hand, which is a flicker of exactly the kind round 3 just removed. It
        matters more now precisely because a fast machine sits at the top with real
        headroom, which is the state that banks a step-up streak.
      Note what round 3's resampling fix contributed to the REPORT: nearest-neighbour
      upscaling looks crisper than it is. Replacing it with honest smoothing removed a
      fake sharpness that had been masking the halving, so the blur was always there
      and became visible when it stopped being blocky. The answer is not to go back to
      blocky; it is to stop magnifying at all, which is what asking for the settle's
      resolution does.
- [x] **Round 3c — the hole 3b opened, closed before it could be reported.** Removing
      the half-resolution cap quadrupled the bytes a frame hands to the display path:
      a fit draft went from ~4 MB to ~17, a zoomed one from ~11 to ~45. And the ladder
      could not see any of it. `draftMs` is wall time measured around
      `await coordinator.render` — actor queueing, render, readback — and stops there;
      the SwiftUI handoff, the body pass, the texture upload and compositing all happen
      after it. A ladder blind to the cost that 3b quadrupled would sit at the top rung
      reporting cheap frames while the picture ticked, which is the exact failure this
      whole campaign started from.
      `DraftLadder.costSample` closes it: when the loop is SATURATED the ladder is
      costed by the interval between delivered frames, which necessarily includes
      everything after the render because the next one cannot start until the main
      actor is done with the last. Saturation is not guessed — `.task(id:)` cancels the
      render task the moment a newer event reaches the view, so a task that finds
      itself cancelled when its frame lands had work queued behind it the whole way.
      A slow hand leaves that false and its long gaps are correctly read as the hand's
      rather than the machine's, which is the false positive that makes the raw
      interval unusable on its own. Five tests, including a fast render (15 ms) inside
      a slow frame (90 ms) that must still walk the ladder down — the case the old
      input could not express at all.
- [x] **Round 3d — the hold from 3b was a one-way ratchet.** Holding the rung during a
      gesture is right: a rung earned back under a moving hand is a visible change of
      sharpness, and at a rung boundary it oscillates. But `allowStepUp: false` also
      RESET the cheap-frame streak, and drags are very nearly the only time this ladder
      sees a frame at all — drafts come from slider edits and otherwise only from a
      photo switch, a zoom or a matte landing. So a comfortable drag could never bank
      anything, and one hard drag on one heavy photograph dropped the rung for the rest
      of the session, leaving every later drag needlessly soft on a machine that could
      afford better. That is this round's own complaint arriving by a different door,
      and it would have been reported as "sometimes it's blurry again".
      The streak is banked while the hand is down and spent by `gestureEnded()` when it
      comes up — one change of sharpness, at rest, invisible. Heat during the gesture
      still clears it, so a drag that ran hot earns nothing: the evidence for a step up
      is a WHOLE gesture of comfortable frames, not a hopeful reset. Two tests, one for
      each half.
- [x] **Round 4 — the blur was never the render size. It was a SECOND quality knob
      nothing could see.** Owner, after 3b and 3d: "when I use the blacks slider I get a
      very blurry image until I let go … honestly all of the sliders are very blurry
      when I move them."
      Removing the half-resolution cap changed what the viewer ASKED for and nothing
      else, because `AppleRawSource.decode` sets `filter.isDraftModeEnabled = draft`.
      That flag is a faster, LOWER-QUALITY demosaic, honoured by Core Image only when
      `scaleFactor` is 0.5 or less. The demosaic is the stage that decides what fine
      detail exists at all, so it is a softer picture at the same size — applied to
      every frame under a moving hand and to none at rest, which is precisely the shape
      the owner reported: blurry while dragging, sharp on release.
      An interactive frame therefore had TWO quality knobs — its resolution, which
      `DraftLadder` measures and controls, and this one, which was hard-coded, invisible
      and unmeasured. The eye notices the second one. And nothing CHOSE it: because the
      flag is honoured only below half scale, a drag frame's sharpness depended on where
      the ladder happened to sit relative to that threshold — a quality cliff at an
      unrelated constant, moving under the control whose whole job is to trade quality
      for speed deliberately. Concretely, on a 45 MP file (long edge ~8200) every rung
      asks for a scale under 0.5 and the coarse decode always applied; on a 24 MP file
      (~6000) the top rung's 4096 is a scale of 0.68 and it did NOT, so the same drag on
      the same machine was sharp until the ladder stepped down and then softer. Nobody
      designed that.
      Fixed by separating them: `renderPreview` takes `coarseDecode` distinctly from
      `draft` (which still governs stale tables and rasters), the viewer's coalesced
      path always decodes at full detail, and the coarse decode stays reachable only
      from the one-shot instrument path. One lever, held by the thing that measures.
      (Checked rather than assumed: both `renderOneShot` callers — the scope proxy and
      the auto-tone probe — pass `draft: false` already, because an instrument must not
      read a stale table. So after this change NOTHING in the app takes the coarse
      decode. Said out loud because the first draft of this entry claimed those two
      probes were the reason to keep it, and they are not.)
      **The better decode should not be paid per frame**, which is what makes the trade
      easy to accept: `AppleRawSource` caches the decode under a key of everything the
      decoder reads, no tone or colour slider moves any field of that key, so every
      frame of a gesture is handed the same lazy `CIImage` — and the context runs with
      `cacheIntermediates: true`, which is what lets Core Image reuse the demosaic
      behind it. Stated as intent rather than measurement: that cache is bounded and
      heuristic, and a ladder step does change the scale factor and so the key. The
      HUD's `draft` line is what says whether it holds on the owner's machine. A second side effect worth having: at the top rung the
      draft and the settle now request the same size AND the same decode, so they share
      a `DecodeKey` and each warms the other, where before every gesture end paid a
      fresh full decode.
      **The instrument that should have caught this was reporting the wrong number.**
      `LatencyHUD.noteDraft` was passed `draftTarget` — the REQUEST — so the HUD's size
      could not disagree with the code that chose it. It confirmed the viewer's
      intention on every frame and said nothing whatever about the frame. It now reports
      the delivered extent and prints "(asked N)" when the two differ. Three rounds of
      looking at the number that was supposed to answer this question, and the number
      was of the wrong thing.
      *Correction, made in the open:* the first version of this entry claimed the draft
      decode halves the picture's DIMENSIONS, citing docs/14's demosaic row ("bilinear
      for draft LOD"). That row describes Lumen's own planned demosaic, not Apple's
      decoder, and Apple's flag does not change the output size. The fix is unchanged —
      it was always "stop putting an unmeasured quality knob on the interactive path" —
      but the mechanism was mis-stated, and the delivered-vs-asked HUD line is better
      read as the instrument that would SETTLE such a claim than as a report of one.
- [x] **Round 4b — the same class, one table over, closed structurally.** `finishLUT` is
      also paired with a fresh scalar (`finishScale`, = `transform.white`) and WAS still
      stale-served, so a draft frame could show `oldTable × newWhite / oldWhite` — not a
      stale picture but one that never existed at any setting.
      **Latent, and worth being exact about why**, because the first version of this
      entry guessed otherwise: `transform.white` is `max(whiteTarget, 1) / 100` and
      depends on nothing else, while `ToneEngine.applyAnchors` writes only
      `whiteAnchorEV` and `blackAnchorEV`. So Whites and Blacks change the finish
      table's KEY without changing its scale, and a stale serve there is correctly one
      event behind. Nothing in the app writes `look.render.whiteTarget` today — the
      recipe field exists with no UI on it — so the defect needs a control that does not
      yet ship. It is not the owner's blur and was never going to be.
      Fixed anyway, and by shape rather than by symptom: `pairedTableAllowingStale`
      stores the scalar each table was baked with and returns it, so `finishScale` is
      whatever pairs with the table actually served. The general rule this project has
      now paid for twice, stated once: **a table whose value is meaningless without a
      companion computed fresh must never be served stale without its companion.** The
      cube was made exact because it is cheap (32³ of a 1-D lookup); the finish table at
      15–18 ms cannot be, so it stays stale AND stays paired — which is what the stale
      path was always documented as doing. `AccuracyProbeTests` covers it by driving
      `look.render.whiteTarget` directly, since no slider can reach it; watched failing
      first, with the draft frame showing the 100-target table scaled by up to 3.2×.
      **The fix created the same defect one stage over, which is worth recording.**
      `applyLocalCurves` — in `RenderGraph` and again in `ReferenceRenderer` — asked for
      `plan.displayWhite` while operating on pixels whose white is `plan.finishScale`.
      Those were the same number until a draft frame could carry a stale finish table,
      and then they were not: a local point curve would have been denominated in a white
      its pixels did not have. Both now read `finishScale`, which is what the comment
      above the GPU one already claimed. Separating two values that used to be equal
      means auditing everything that read either — the danger of a fix like this is not
      the line it changes, it is the lines that were silently relying on an equality.
- [x] **Round 4c — the ladder was about to mistake its own transition for its
      destination, and round 4 made that worse.** Found by asking what round 4's own
      change costs rather than by waiting for it to be reported.
      The ladder's lever is the DECODE SCALE: `renderPreview` derives `scaleFactor` from
      the size it is asked for, `graph.build` runs the whole graph at the decoded
      resolution, and `applyGeometry` scales only afterwards. That is what makes a lower
      rung genuinely cheaper — and it also means asking for a new rung is asking for a
      decode key `AppleRawSource` has never seen. The first frame at every new size pays
      a fresh RAW decode that no later frame at that size pays, and on a 45 MP file that
      decode is the largest single cost in the interaction. Round 4 made it a
      full-quality demosaic instead of a cheap one.
      Believed, it cascades: a hot frame steps down, the first frame at the new rung
      pays a decode and is therefore also slow, the ladder reads "the step did not
      help" and steps again, which pays another decode. `DraftLadderTests` runs that
      fixture and it walks all eight rungs to the 576 px floor on a machine whose
      steady-state cost at the second rung was comfortable. What the photographer would
      see is a drag that starts sharp and gets BLURRIER the longer they hold the
      slider — this round's own complaint, arriving through the mechanism meant to
      prevent it.
      `DraftLadder.isRepresentative` is the rule: a sample counts only when the previous
      frame was rendered at the same size, so the first frame of a session, of a zoom
      and of every rung change is skipped. The price is that an unaffordable rung is
      caught on its second frame rather than its first, which is a test of its own. The
      same fixture with the rule applied stays at the top rung.
      *Also checked and ruled out, so it is not investigated again:* the sliders' own
      value quantization. `LumenSlider` snaps to `step`, and the tone controls are
      ±100 at step 1 over a track of about 150 pt — roughly 1.5 device pixels per
      distinct value. No hand can move slowly enough to see that, so the ticking was
      never the control; it was always frame delivery.
- [x] **Round 4d — measured the CPU half, killed two suspects, and printed the number
      that decides the last one.**
      `PlanCostProbeTests` in a RELEASE build, which is the first time this project has
      had that number: plan construction on the DRAFT path is **1.22 ms** (exposure),
      **1.52** (whites), **0.96** (saturation), **1.01** (texture). Against a ~35 ms
      frame that is 3–4%, and stale-while-bake is doing exactly its job — whites costs
      1.52 ms drafting against 16.77 ms settling, an 11× gap.
      *Suspect killed:* the tone gain cube. It is a 32³ = 32 768-sample cube whose value
      depends only on `encoded.r` and is gray, applied to `logLuminance` — which is to
      say a 512 KB three-dimensional texture, rebuilt and uploaded per frame, encoding a
      ONE-dimensional function of 32 values, on exactly the six sliders a photographer
      reaches for first. That is a genuine 1024× redundancy and it looked like the fixed
      cost the ladder cannot touch. It is not: exposure (which re-keys the cube and
      nothing else) costs 1.22 ms against texture's 1.01 ms, so the whole bake is about
      **0.2 ms**. Restructuring it to a 1-D lookup would be mathematically exact — for a
      gray input, trilinear along the diagonal IS linear interpolation — and would save
      nothing worth the risk to the goldens and the parity lane. Recorded so it is not
      rediscovered and "optimised" by someone reading the redundancy without the
      measurement.
      *Suspect killed:* the sliders' own quantization (see round 4c).
      **What is left is the display path, and the HUD now prints it.**
      `DraftLadder.afterRenderMilliseconds` is the interval between two delivered frames
      MINUS the render's own wall time, while the loop is saturated — the CGImage
      handoff, the body pass, the texture upload, compositing. `costSample` already
      folded that quantity into the ladder's input; this reports it separately, because
      the ladder needs one number to act on and a person needs to know which half is
      large. `draft` large and `after` small is the render, which the ladder already
      handles. `draft` small and `after` large is the Metal-plate case, which nothing in
      this app has ever measured and which no resolution reduction touches.
      `DragProbeTests` says in its own header that it stops one step before this; that
      step is now taken, in the app, where it happens. Four tests, including that an
      idle hand is not a display cost and that a render longer than its own interval
      reports zero rather than negative time.
- [x] **Round 4e — a THIRD explanation for a stepping slider, which every instrument
      this project has built would have called healthy.**
      Whites and Blacks move the tone ANCHORS, so they re-key `finishLUT` on every mouse
      event. The drag rides `tableAllowingStale` while the exact bake — 15 to 18 ms of
      35 937 samples, measured — runs on `bakeQueue`. Which means the picture's visible
      response to those two controls is gated by the BAKE rate, not the frame rate: the
      renderer can deliver thirty honest frames a second that are all the same picture,
      because they are all reading the same stale table, and the picture only moves when
      a bake lands. Thirty frames a second showing ten distinct pictures is a slider
      that ticks — and `in/out`, `draft` and `after` would every one of them look fine
      while it happened.
      The counters existed; only the totals were shown, which cannot be read during a
      drag. `bakesPerSecond` / `staleServesPerSecond` sample the cache's own totals once
      per delivered frame and print them as rates. `stale/s` near the input rate with
      `bakes/s` far below it is the signature, and it points at the engine (a cheaper
      finish bake) rather than at the render or the display path.
      NOT yet acted on beyond the instrument, deliberately. The bake is ~15 ms on the
      probe's CPU and likely faster on an M-series machine, which would put table
      updates at 60–100/s and make this a non-issue; the mechanism is real but its
      MAGNITUDE is unknown, and this round has already twice been wrong about a
      mechanism it had not measured. The candidate fixes — a cheaper bake, a narrower
      `concurrentPerform` so the bake stops stealing every core from the render, or
      keeping the anchors out of the baked table — differ enough that guessing between
      them is how the last two wrong calls happened.
- [x] **Round 5 — THE ONE. The decode cache cached the intention to decode, and every
      drag frame re-demosaiced a 33 MP file.** Found in one screenshot from the owner's
      machine, after four rounds of reasoning could not get there:

          in/out      106/s    4fps
          input→draft 368.7 ms
          draft      457.5 ms @2048
          settle      14.5 ms @2560

      `in` at 106/s kills the input-coalescing theory outright — the app sees the hand
      perfectly. 4 fps is the ticking, exactly: four distinct pictures a second. And the
      decisive pair is the last two lines. **A draft at 2048 px cost 457 ms while a
      settle at the LARGER 2560 px cost 14.5 ms** — thirty times slower at a smaller
      size. No graph over 2.8 megapixels does that; a 33 MP demosaic does.
      `AppleRawSource.decodeCache` stored `filter.outputImage`: a lazy `CIImage`, a
      description of a decode rather than its pixels. Every frame that got a cache HIT
      re-ran the full RAW demosaic on the GPU. `cacheIntermediates: true` was supposed
      to rescue it, but that intermediate is a ~260 MB RGBAh buffer, far past what the
      cache holds, so it was evicted and recomputed on every frame of every drag for the
      life of the app. Fixed by rendering the decode into real pixels once per key —
      half-float RGBA, IOSurface-backed, in the working colour space, because what
      leaves that file is scene-referred and an 8-bit materialization would throw away
      the highlights the pipeline exists to protect. Above 3072 px it stays lazy: an
      export decodes once and uses it once.
      **AND ROUND 4 MADE IT WORSE BEFORE IT MADE IT BETTER.** Turning off the coarse
      decode meant each of those repeated demosaics became a full-quality one. That
      change was right for sharpness and wrong while it was happening per frame; it is
      right now, because it happens once.
      **What the four rounds of reasoning got wrong, stated plainly**, since the pattern
      matters more than the bug: `DragProbeTests` priced this exact defect at single
      digits of percent and its own header said to treat that as a FLOOR because its
      source is synthetic — a two-filter generator chain standing in for a demosaic. The
      caveat was correct and was read as noise, and "materializing the decode is worth
      ~10%" was recorded and then withdrawn. A probe whose SUBJECT is synthetic cannot
      bound a cost that lives entirely in the thing it replaced. Every round after that
      optimised around a 457 ms constant nobody had measured, which is why the ladder,
      the tables, the resampling and the display path all looked like plausible
      explanations: against 457 ms they were all rounding error.
      *Expected*: `draft` from 457 ms to tens of ms; the ladder then earns its rungs back
      at gesture end, and once it returns to the top the draft and settle request the
      same size, share one materialized decode, and the drag pays no decode at all.
- [x] **Round 5b — the ladder recovered from the round-5 defect at one rung per gesture,
      so fixing the decode left every slider blurry anyway.** Owner, on the build with
      the decode fix in it: "If I still move the sliders around, any of the sliders, they
      are still extremely blurry. The entire image just turns very, very blurry."
      Not a failure of the decode fix — a consequence of it. While every draft frame cost
      457 ms the ladder did exactly its job and walked to the 576 px floor (the earlier
      screenshot already shows it at 2048 on the way down). A 576 px frame magnified to
      a 16-inch pane is about 4×, which is "very, very blurry" precisely. Then the decode
      was fixed, frames became cheap — and climbing was `stepUpAfter` = 12 consecutive
      cheap frames for ONE rung, spent once per gesture by `gestureEnded`. From the floor
      that is eight more drags. Down fast and up slow is right for a machine that cannot
      afford the top rung and wrong for a TRANSIENT, and a fixed defect is a transient.
      The evidence to climb was already being measured and thrown away: every gesture
      ends with a settle, which is a render at the full requested size timed by the same
      clock. `recordSettle` uses it, and it is CONSERVATIVE evidence, which is what makes
      this sound rather than hopeful — a settle pays exact table bakes where a draft
      serves them stale, so a settle inside the budget PROVES a draft at that size is
      inside it. An inequality, not an estimate. It only ever climbs, never claims a size
      it did not measure (a cheap settle at 1280 says nothing about 4096), and one settle
      is enough, so recovery is one gesture instead of eight. Four tests, including the
      owner's exact scenario: 40 frames at 457 ms to the floor, then a single 14.5 ms
      settle at 2560 restoring it.
- [x] **Round 5c — swept the codebase for the same bug class, and it is a population of
      one.** A cache that stores a lazy `CIImage` stores the INTENTION to compute rather
      than the result, and every "hit" pays the work again. That cost this project four
      rounds, so the question is whether it appears anywhere else.
      It does not. `ThumbnailLoader` holds `CGImage` with a byte-budgeted LRU;
      `MaskRasterCache` holds `Plane` float buffers; `PlanTableCache` holds baked
      `LUT3D`s; `RenderGraph.maskImages` is per-render state, not a cache.
      `AppleRawSource.decodeCache` was the only one holding a promise — and the reason
      is instructive rather than careless: its entries were CHEAP while they were lazy,
      which is exactly why nobody counted them and why eight of them seemed free. The
      byte budget added with the materialization is the same pattern `ThumbnailLoader`
      has had all along; the decode cache was the outlier only because its entries used
      to weigh nothing.
      Also verified: the materialization preserves the scene-referred range that the
      whole RAW contract exists to protect. `MaterializedDecodeTests` writes 4.0, 2.5
      and 1.75 above display white and −0.25 below zero through the round trip and reads
      them back, because a clamp there would fail NOTHING downstream — the goldens use a
      stub source, and the parity tests would compare two renderers reading the same
      clamped input. Every photograph would just quietly lose its highlights.
- [x] **Round 5d — the ladder's own instrument was aiming it at a target it could not
      hit, and it was my regression.** Owner, on the current build: "the numbers work
      fine with the drag ... it's just when I'm holding it down, the image is actually so
      horrible ... it looks like the worst version of a photo ever", with two screenshots
      showing a drag frame and a settle frame side by side.
      His HUD said the rest. `draft 10.8-12.0 ms @576` — the ladder pinned at its
      ABSOLUTE FLOOR while costing a third of the 35 ms budget. Three times the headroom
      it needed, sitting at the bottom. And `after` — the delivery overhead the render's
      own timer cannot see — read 0.1 ms or 0.00 ms on the large majority of frames and
      spiked to 285, 378 and 399 ms on scattered ones.
      Two defects, both mine, both introduced in round 5b with `costSample`.
      1. **The descent was acting on heat it had no lever against.** `record` was fed
         `costSample` = `max(render, frame period)`, and read every one of those 285-399
         ms outliers as one sample eight times over `stepDownOver`. Each dropped a rung,
         so the ladder walked to the floor inside a single drag and stayed there for the
         session. But a 399 ms interval around an 11 ms render at 576 px — 1.3 MB of
         image — is not an upload cost, and there is NO smaller draft that would have
         avoided it. The ladder was spending its one lever on a disturbance the lever
         has no authority over, and paying for it in sharpness.
      2. **The climb was judged on a number that cannot answer its question.** The
         cheap-frame streak was ALSO fed `costSample`, so on any machine whose frame
         period is floored above `stepUpUnder` (17.5 ms) by something other than pixels,
         the streak can never accumulate however cheap the renders are — the ladder can
         be permanently pinned by its own arrival rate.
         **CORRECTED, same session:** this is a latent hazard the fix removes, and it is
         NOT what happened to the owner. It was written up here as the second half of
         his defect on the assumption of a ~28 fps loop. The table counters say the loop
         was running at about **92 frames a second** — `bake/stale 92/s 0/s` is one
         exact tone-cube bake per plan and therefore 92 plans a second, reproduced
         against his `tables 2241h 2230b` — so his frame period was ~11 ms, well under
         the threshold, and the climb was reachable throughout. What actually held the
         ladder down was defect 1 resetting the streak faster than twelve frames could
         rebuild it. Recorded rather than quietly edited because reasoning from an
         assumed frame rate is the mistake, not the arithmetic.
      Down fast, and up too slowly to matter — which is the picture the owner described.
      The fix splits the evidence, because the two directions ask different questions.
      The DESCENT is judged on what the hand felt and the CLIMB on what the render cost,
      since the render is the only part of the interval resolution can change. A hot
      render still steps down on one sample — pixels caused it, fewer will fix it. Heat
      found only in the delivery interval must now REPEAT (`stepDownRunOnDelivery`, 2)
      before it counts: sustained, it is a real cost fewer pixels can relieve; once, it
      is a stall, and the answer to a stall is to find the stall. The climb requires a
      cheap RENDER at the rung and additionally `cost < budgetMilliseconds`, which leaves
      a dead band between the budget and `stepDownOver` where the ladder holds still —
      the right move when neither direction would help, and the hysteresis that stops the
      new climb rule from oscillating against the new descent rule.
      `recordSettle` is unchanged and was not the bug; its `ms < budget` guard is sound
      in one direction only, and the owner's 87.5 ms settle at 2560 genuinely proves
      nothing about a 35 ms draft. Its header now says so, because it had been written
      as a general fast path and it is a strong-machine one.
      Eight tests. The headline one replays the owner's trace — six bursts of twelve
      11 ms frames with a 285/378/399 ms stall between them — and asserts the ladder is
      still at rung 0. Under the old rule that trace reached the floor.
      Still open: the stall itself. The ladder no longer dives on it, but a 399 ms hitch
      is a 399 ms hitch and the hand feels it. Under investigation separately.
- [x] **Round 5e — the instrument the last three rounds reasoned from was measuring
      something else, and it named the stall.** `afterRenderMs` has been documented
      since it was written as "the CGImage handed to SwiftUI, the body pass, the texture
      upload, compositing" — the half of a frame a resolution ladder cannot fix and a
      Metal-layer viewport would. Every argument for that plate has cited it. The
      arithmetic never supported it and was always available:

          period  = landedAt(N) - landedAt(N-1)
          draftMs = landedAt(N) - draftStarted(N)
          period - draftMs = draftStarted(N) - landedAt(N-1)

      `draftStarted` is stamped BEFORE the await (`LoupeView.swift:531`), so queueing,
      render and readback are all inside `draftMs`. The remainder is the gap between one
      frame LANDING and the next being REQUESTED. No part of the display path is in it.
      It is normally zero or negative — `.task(id:)` starts frame N+1 without waiting
      for N — so the `0.00` that dominated the owner's readings is the `max(0, ...)`
      clamp, not a free display path.
      Which means a large `after` says the request stream STOPPED. Mid-gesture, with the
      button still down, that is the hand pausing. And the saturation guard meant to
      exclude exactly that was sampled at one end only: `Task.isCancelled` read when the
      frame lands answers "was work queued behind this frame", never "was work queued
      when the interval opened". A pause followed by a hard resume passes it, and the
      whole pause is charged to the machine. 285, 378 and 399 ms all sit under
      `continuityCeilingMilliseconds` — the band a hesitation occupies, not the band a
      stall does.
      `DraftLadder.loopWasSaturated` now requires the previous frame to have been
      cancelled too, and the viewer carries that forward (`lastDraftWasSaturated`).
      Four tests, including the owner's trace reaching the ladder as an 11 ms frame.
      **And a real stall was found underneath it, in the place the guard was missing
      entirely.** `PhotoRenderModel.load` defaults `settleTick: 0` and
      `gestureInFlight: { false }`, and **neither compare-pane call site passed either**
      (`CompareView.swift:262`, `:470`). Their `.task(id:)` is keyed on
      `ViewerRenderKey`, which contains the recipe — so with a pane open, every mouse
      event of a drag scheduled a FULL-RESOLUTION settle on the same serial coordinator
      the loupe's drafts queue on, whose passes have no cancellation points. That is
      verbatim the defect `LoupeView.swift:637-651` documents and fixed in one place
      only: "once one started every event behind it waited 100-300 ms for a lane that
      could not be given back." Stack three and it is 285-399 ms, landing in the loupe's
      frame interval. Both sites now pass both arguments — the tick is not optional
      beside the guard, since the guard skips the settle and the tick is what asks for
      it again. Those panes' ladders also receive their first-ever `gestureEnded()`.
      `beforeModel` (`LoupeView.swift:1024`) deliberately does NOT get the guard:
      `BeforeKey` carries no tick, so it would trade a rare extra settle for a
      permanently soft before rendition — and `beforeRecipe` does not move while the
      edited section's sliders do, so there is no storm there to stop. Written down at
      the call site.
      Also fixed: the HUD printed a sticky `after` directly beneath a per-frame `draft`
      and captioned them "one frame split in half". They routinely were not, and a whole
      round of diagnosis was built on `draft 10.8 @576` sitting next to `after 399`. The
      `after` line now carries the draft it was actually measured beside.
- [x] **Round 5h — the settle's 312 ms was one constant written down three times, and
      the third copy said 3072.** `DecodeMaterializer` exists to stop a decode being
      cached as a PROMISE: above its `longEdgeLimit` it returns nil and `AppleRawSource`
      stores the lazy `CIRAWFilter.outputImage` instead, so every "hit" re-runs the full
      RAW demosaic. Its own header named the sizes it was protecting — "every INTERACTIVE
      size is below this: the viewer's settle, every rung of `DraftLadder`" — and the
      claim was false. `rungs[0]` and `LoupeView.maxRenderLongEdge` are both 4096, and at
      any zoom the viewer asks for exactly that, so the settle sat one rung above the
      line. Owner's HUD: `draft 8.5 ms @2048` beside `settle 312.7 ms @4096`.
      Fixed by deleting the third copy, not by changing its value:
      `DraftLadder.interactiveLongEdgeCeiling` is the top rung and the materializer reads
      it. **It also repairs a regression 429b403 would have shipped** — that commit's
      goal is to reach 4096 in three gestures, so the first draft to arrive there would
      have paid the demosaic, stepped back to 3072, refilled the streak and climbed into
      the same cliff again: one multi-hundred-millisecond stall per zoomed gesture, worst
      on the FASTEST machines because only they get there. Its test passed because it
      models cost as `8.5 x (edge/2048)^2` and exits at rung 0 without ever recording a
      frame AT 4096 — the test modelled away the one discontinuity that mattered.
      Prediction stated so it can be wrong: the first settle per photo and scale still
      pays one demosaic and every settle after it becomes a hit. No probe in this repo
      has ever priced a render above 2048, so "the 312 ms is really superlinear graph
      cost" remains open; one glance at the HUD settles it.
      Also fixed alongside: the settle HUD line printed the REQUEST while the delivered
      extent sat on the line above feeding the ladder — the identical defect already
      argued and fixed on the draft line, unfixed on its sibling.
- [x] **Round 5g — the climb stopped three rungs short because it asked one question
      for every step.** Owner on the round-5 build: "I can still see slight blur, but
      this is a whole lot better than it was before ... if we can remove it fully, that
      would be great."
      His HUD: `draft 8.5 ms @2048`, `after 0.0 (its draft 9.7)`, `49 fps` against
      `55/s` input, `settle 312.7 ms @4096`, at **217% zoom**. The ladder had climbed
      576 → 2048 and the stalls were gone. What was left is arithmetic: at 217% the
      settle is 4096 and the draft 2048, so the picture under the hand was half the
      settle's LINEAR size. Exactly one factor of two of softness, which is what
      "slight blur" looks like.
      And 8.5 ms against a 35 ms budget is four times the headroom. Projecting from his
      own number: 2560 ≈ 13 ms, 3072 ≈ 19, 4096 ≈ 34. **His machine can afford the top
      rung.** The flat `stepUpUnder` of half the budget (17.5 ms) refused the last two
      steps.
      THE CONSTANT COULD NOT HAVE BEEN RIGHT, because the rungs are not evenly spaced:
      2560 → 3072 is 1.44x the pixels, 3072 → 4096 is 1.78x. A threshold safe for the
      larger step needlessly refuses the smaller; one safe for the smaller overcommits
      on the larger. So `stepUpFits(renderMilliseconds:at:)` asks the question the step
      actually poses, per step: would `cost x (to/from)^2` still fit the budget?
      Deliberately an OVERESTIMATE — measured per-rung costs are markedly sublinear,
      since a frame carries fixed overhead that does not shrink with the picture
      (`DragProbeTests`: 576 → 1024 triples the pixels for 1.4x the cost) — so a "fits"
      is an inequality rather than a hope, which is the only claim worth spending a rung
      on. `stepUpUnder` is gone; nothing else referenced it.
      Five tests. The headline one replays his measurement — cost scaling with pixels
      from 8.5 ms at 2048, the projection's own law rather than a flattering one — and
      asserts the ladder reaches 4096 in exactly three gestures. Its sibling gives a
      machine two and a half times slower and asserts it is NOT sent to a rung it cannot
      afford, and that wherever it settles is itself inside the budget.
      Still visible in that HUD and not addressed: `settle 312.7 ms @4096`. That is the
      pause between letting go and the picture sharpening, and it is nine times the drag
      budget.
- [x] **Round 5f — 4 MB of a constant table copied to the GPU on every frame.**
      `ColorCube.filter` built a fresh `Data` from its LUT on every call.
      `DitherStepCube` is 64³ in RGBA floats — 4 MB — and the dither is not
      export-only: `renderPreview` dithers every frame it shows, so that the loupe does
      not band where the file will not. At the frame rate a drag produces (~92/s,
      measured) that is several hundred megabytes a second of transient allocation for
      a table identical to the one on the previous frame, and a fresh `Data` each time
      also denies Core Image any chance of reusing the texture behind an upload it
      already holds.
      `ColorCube.Baked` holds the bytes, copied once; `DitherStepCube`'s four
      `static let`s hold it instead of the `LUT3D`. Footprint is unchanged rather than
      doubled — the `[Float]` is released once the copy is taken.
      THE BYTES AND NOT THE FILTER, deliberately. A `CIColorCube` is a mutable
      Objective-C object whose `inputImage` every caller writes, and `ColorCube.filter`
      is a public static reachable from any thread; `RenderCoordinator` being a serial
      actor does not cover it, because `PipelineRenderer` has no isolation of its own,
      export never goes through the coordinator, and pipeline work runs from
      `Task.detached` workers while `MaskRasterCache` bakes on its own queue. Two
      overlapping renders on one shared filter would race on `inputImage` and produce a
      frame of the WRONG PHOTOGRAPH — a picture bug bought with a performance fix.
      `Baked` holds only `Int` and `Data`, so a `static let` needs no lock and no
      `@unchecked`; verified by compiling the alternative, which warns under Swift 5
      strict concurrency and errors under 6.
      Every plan-owned table still rebuilds per frame by design — finish, colour grade,
      tone gain, each mask's local curve, the fallback tone cube. Caching one of those
      would freeze a photographer's edit on screen.
      **VERIFICATION GAP, stated because it is not small:** every file in
      `LumenPipeline` is `#if os(macOS)`, so the module compiles EMPTY on Linux and the
      local suite cannot type-check or run this change — `--filter LumenPipelineTests`
      executes zero tests. What stands behind it is `swiftc -parse`, the surface checker
      (mutation-tested against a renamed type), and the macOS lane. The two new golden
      tests first really run there.
      Two more instances of the same class found and deliberately NOT changed:
      `PipelineRenderer.grainPlate` rebuilds three 128×128 tiles and re-runs the CPU
      noise generator every frame when a grain stock is on (~768 KB, needs a keyed cache
      rather than a `static let`), and `ditherPlate` rebuilds the constant 8×8 Bayer
      cell every frame (~1 KB, and the cacheable object is a non-`Sendable` `CIImage`,
      which is not worth the risk for a kilobyte).
- [ ] **Deliberately NOT done in round 2: anything else to the render or display path.**
      The display path above is the leading suspect and a `CALayer`-contents or
      Metal-layer plate is the obvious next move — and shipping it now, unverified,
      would confound the one test that decides whether round 2's two fixes worked. If
      the owner drags a slider on this build and it is still not smooth, that has to
      mean "the fixes were not enough", not "something new was added at the same time".
      Three rounds have failed by stacking speculative fixes; this one stops and reads
      the instrument first. The HUD can now tell the display path apart from the render
      on its own — see the third case in the checklist's decision tree.
- [ ] **Owner verification of round 2, and the next lever if it is still not smooth.**
      Scripted as `docs/sessions/03-checklist.md` — seven steps, ~15 minutes, of which
      step 1 is the whole point. Run the build with the HUD on (⌘⌥L) and drag any
      slider. Read `in/out`:
      · in high, out low → the render is the bottleneck, and the per-rung numbers say
        pixels still help: the ladder should be walking down on its own now, so read
        the HUD's `draft ms @size` to see which rung it settled on before reaching for
        the graph itself.
      · in and out both low and equal → input is still being dropped on the main
        actor; next lever is `AppState` → `@Observable` for per-property tracking, of
        which round 2's two small observables are the first step, not a substitute.
        Second candidate on that branch, cheap and untried: `LumenSlider`'s track is a
        `GeometryReader`, so the active panel nests ~15 layout containers per body
        pass purely to learn a width that is constant — the develop column is a fixed
        `Lumen.panelWidth`. Measuring it once into `@State` would remove all of them.
        Not done in round 2 deliberately: it is a change to the one slider every panel
        uses, made before the measurement says the main actor is still the problem,
        which is the shape of the three rounds that failed.
      Also still open, unchanged and now ranked BELOW the above by measurement:
      `PipelineRenderer.maskSource` is uncached and rebuilds a 1024-px staging render
      per frame whenever any mask reads the picture; `requestedLongEdge` asks for a
      flat 4096 when zoomed rather than what is visible; `updateRecipe` builds two full
      `renderIdentity` projections per photo per event.

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
