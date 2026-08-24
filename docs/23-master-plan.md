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

- [ ] HEAD compiled by CI (push; run #182 died with zero jobs — transient allocation)
- [ ] **gpu-parity (proof-macos) dispatched for the first time in project history**;
      every red fixed or XCTSkip'd with an issue reference — no silent skips
- [ ] The two stale proof records re-pinned (tone.exposure ±2→±5, raw.tint ±100→±150),
      per-record rationale in the commit; drift lane watched failing on a wrong record
- [ ] CI restructured:
      - [ ] `ProofSmokeTests` (~8 sentinel controls × 5 steps) in engine-linux, per push
      - [ ] `gpu-parity`: paths-filtered push (LumenPipeline/Engine/Image + pipeline
            tests) + nightly + dispatch; skip-list guard greps test-fast's `--skip`
            names against the tree
      - [ ] `proof-linux` full sweep: nightly + dispatch (off push)
      - [ ] `perf-macos`: measure draft@1024/1536/2048, settle@2560, LUT cold bake, one
            24MP export; generous ceilings; numbers to step summary + CSV artifact
      - [ ] `app-bundle`: main + dispatch only
- [ ] Two owner-provided real RAW fixtures committed (<15MB total) unlocking
      AppleRawSource contract tests (as-shot neutral UNITS have never been verified),
      draft-demosaic delta, perf lane, Vision-matte tests
- [ ] De-risking probes run and recorded: (a) full-pipeline draft cost on the runner at
      1024/1536/2048; (b) mask re-raster cost at 1024 on Linux; (c) draft-demosaic
      color delta (needs the RAW fixture)
- [ ] Honesty pass: README's "nobody has run it on a Mac" + line count, CI comment test
      counts, "thirty-two kernels" (there are 33)

**Exit gate:** full CI green including gpu-parity's first-ever run; probes measured.

## M1a — The picture answers the drag

The draft-render redesign — full pipeline at draft resolution, no stage gating:

- [ ] `RenderGraph.swift`: delete the `!options.draft` gates (S3/S8/S11/S12/halation/
      S15b/grain); `draft` survives only where it means something real (draft demosaic,
      noiseScale)
- [ ] `PipelineRenderer.makeGraph`: delete `guard !draft else { return graph }`
- [ ] `MaskRasterCache`: exact-hit reuse; stale-while-drag for source-reading masks in
      drafts; settle always exact; grain plate cached per (stock, extent)
- [ ] `DraftLadder` in LumenCore/Interaction (2048→1600→1280→1024 by measured draft
      time, ≤35ms p95 target), Linux-tested; replaces LoupeView's fixed draftTarget
- [ ] `PlanTableCache` stale-while-bake: interactive plans may get the newest stale
      table while a single-flight background bake computes the exact one; settle +
      export ALWAYS exact; capacity 4→8; Linux tests (converges in one call,
      non-interactive never stale, single-flight coalesces)
- [ ] `onEditingChanged` consumed: settle at finger-up; catalog writes + fingerprints
      per-gesture; scope timer armed once; overlay raster deferred during drag
- [ ] **`DraftTruthfulnessTests`** (macOS CI): draft vs settle at the same size on a
      recipe exercising every formerly-gated stage — the permanent lock

App-layer waste, low-risk first:

- [ ] FilterBar's 14 counts + Sidebar's 2 filters + editTargets scans memoised;
      BasicPanel's 16 Recipe copies/pass eliminated; logic in LumenCore where testable
- [ ] ScopesView raster off the main thread, memoised per scope generation
- [ ] AppleRawSource decode cache: single entry → small keyed cache
- [ ] refreshMaskOverlay cancellable; supersession checked BEFORE the actor call
- [ ] PixelSampler lazy (only when readout/clipping overlay is on)
- [ ] RenderKey construction unified; CompareView adopts it (kills the still-live
      half/double zoom pump + stale-mask defects there)
- [ ] Then, ONE isolated revert-friendly commit: AppState → `@Observable`
      (56 props, 25 sites, 19 files)
- [ ] `LumenAppTests` target; first tests: memoised counts, keyed decode cache,
      RenderKey parity across views

## M1b — Truth polish + instrumentation

- [ ] The ε=0.004 tone-mask measurement (`ToneMaskEdgeTests`, Linux): step edges
      Δ∈{0.5,1,2,3} EV at r=20px ± noise variant, through the real RenderPlan path;
      halo_EV > 0.1 at Δ∈{1,2} convicts; candidate fix ε′ = 0.004/24² ≈ 6.9e-6 in
      ReferenceRenderer + RenderGraph in lockstep; noise-residual guard < 0.02 EV
- [ ] Preview dither / deeper intermediate (loupe banding the export doesn't have)
- [ ] Latency HUD behind a debug key (drag→photon, draft/settle ms, ladder rung, cache
      hits) + os_signpost around decode/plan/rasterize/render
- [ ] Last folder remembered across launches (security-scoped bookmark; the schema
      column exists with no writer)

**Owner session A:** drag every basic slider on a masked, denoised, sharpened real RAW —
nothing may change on release; Highlights/Whites/Blacks judged with the HUD visible
(settles MAC-04 with evidence); zoom stability; double-click reset.
**Exit gate:** sliders feel immediate; no pop-on-release anywhere; MAC-04/MAC-07 closed
or precisely characterized.

## M2 — The basics are right

- [ ] Tone-cube knot-density measurement (2 EV shelf through the 32³ cube vs direct
      evaluation, Linux); 64³ or non-uniform knots only if the data says so
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
