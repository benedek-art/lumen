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
- [ ] Still owed from that bullet: os_signpost around decode/plan/rasterize/render,
      and cache-hit counters on the HUD
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
or precisely characterized. **NOT YET MET**: the owner reports steppy, late-feeling
updates ("switches little by little instead of a ramp") and no HUD numbers were
captured — next session retests zoom + double-click and brings input→draft/draft-ms
numbers; the steppiness suspect list is (a) pre-fix zoomed full-res drafts (fixed),
(b) tone-LUT knot quantization (M2's first measurement, promoted).

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
- [ ] Remaining calibration contracts: Contrast pivot invariance as an assert (the
      probe shows it holds), Temp writes the Kelvin it shows, endpoint targets per
      control, Highlights/Shadows range-compression targets
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
- [ ] Dossier-driven fix queue (full detail in docs/24; ranked by daily impact):
      1. Zones panel DEFECT: stored default pivots put "Midtones" at scene −2 EV
         (docs say 0 EV) and "Darks" at −7.9 EV where the toe shows nothing
      2. Sharpen Radius in output pixels — preview judgment ≠ export (M3 item,
         now with the exact fix site named)
      3. Mixer band centres are geometric (29.23°+45°k), not perceptual — orange
         sits ~21° off, foliage lands in Yellow's core: the single largest LR
         muscle-memory break; fix or formally accept
      4. Masked grade reads default zone pivots, contradicting its own documented
         contract (COLOR-16); masked Sat/Vibrance inherit invisible
         density/protectSkin defaults (COLOR-27)
      5. Point Color's eyedropper samples post-S6 while the engine compares at its
         stage input — a swatch picked with tone moves selects the wrong colour
      6. Dehaze GPU: sky guard missing on + branch, skyness on − branch (skies get
         more correction than the reference defines)
      7. Denoise luminanceAnchors: the same σ double-count measured-and-fixed for
         chroma, unmeasured for luma; one ISO-25600 harness run settles it
      8. Tint clamp unsurfaced (engine right, UI silent) + as-shot Kelvin/tint
         units unverifiable without RAW fixtures
      9. Capture sharpening: wire the dormant Richardson–Lucy or remove the dead
         Radius control (M3 decision, already listed)
      10. Texture one-band spectrum vs reference band-pass unmeasured post-fix;
          proof-registry holes (color.density, protectSkin, mixer.uniformity,
          colorBalance.*); H-K and tuning constants unpinned
- [x] Owner decisions on the dossier's deliberate divergences (2026-08-26, in
      chat): KEEP the compressed saturation push ("we want something subtle very
      often, a saturation that doesn't really look like it's been edited" — the
      design IS the preference), KEEP the luminance-preserving curve default, KEEP
      pure-gain Exposure. Still open: hard tone-zone partition vs LR feathering —
      decided after the LR side-by-side exports exist.
- [ ] UI/IA round from the same session: Basic panel reordered Tone → Presence →
      WB → Colour (done); DevelopNote collapsed to a hover-ⓘ except honesty
      notices (done); double-click-on-track reset already fixed, owner saw an old
      build; DEEP visual/UX redesign requested ("looks like very old Apple") —
      design audit in flight, direction proposal before any repaint
- [ ] First shipping-path golden that MOVES the six tone sliders through RenderGraph,
      preview + export scale
- [ ] Tint honesty: tintLimit surfaced like effectiveHighlights; WB eyedropper cheap
      again (cache the bisection)
- [ ] Re-verify-then-fix at HEAD (the audit ledger is stale — verify first): TONE-01
      as-shot Kelvin · TONE-34 Auto highlight branch · COLOR-25 Protect Skin at
      Sat −100 · denoise Colour dead zone + ISO defaults incl. the unmeasured
      luminanceAnchors double-count · Sharpen Detail direction · PROOF-04
      zones.dark.ev invisibility · PROOF-03 Primaries purity clamp · double-click
      reset vs the track-jump
- [ ] Proof records at full panel travel for every Basic-list control; the 13 missing
      sliders recorded; P1 REACHES made mechanical (test fails when shippingReader
      file:line drifts)
- [ ] P6 baselines vs darktable/RawTherapee for tone, S/H recovery, dehaze, sharpening
      — first recorded competitive evidence, per docs/20 tier rules

**Owner session B:** re-edit 5 previously-Lightroom-edited photos, basics only,
side-by-side exports. **Exit gate: owner prefers or ties Lumen on ≥4 of 5.**

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
