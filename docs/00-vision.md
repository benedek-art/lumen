# 00 — Vision

This document is the constitution of the Lumen plan. Every spec in this package (04–12), the
architecture (13–15), and the roadmap (16) must be defensible in terms of what is written here.
When a future decision is in tension with this document, either the decision is wrong or this
document gets amended explicitly. Nothing drifts silently.

## 1. The thesis, and why now

**Lumen is Photo Mechanic's culling speed + FastRawViewer's raw truth + Lightroom's workflow
grammar + Capture One's color + Resolve-grade grading depth + DxO-class denoise ambition, in one
native macOS app, local-only, subscription-free.**

No product on the market combines even three of those six. Photo Mechanic culls but cannot edit.
FastRawViewer tells the truth about raw files but does nothing with it. Lightroom Classic has the
grammar everyone's hands know and spends it on a five-way slow engine. Capture One has the color
and burned its customers on pricing. Resolve has the grading depth and is a video tool. DxO has
the denoise and a modal, plodding workflow. The seam between the culling tools, the raw editors,
and the colorist tools is an open market position, and the literature review (docs/01-research-literature.md)
found the same seam in the bookshelf: no single canon unifies stills workflow with colorist-grade
tooling. Lumen is built directly on that seam.

The timing is not incidental. The field of "own your tools" macOS photo software has been
evacuated, vendor by vendor, and every departure is documented in docs/03-research-competitors.md:

- **Apple** acquired the Pixelmator team (2024/25); Pixelmator Pro and Photomator are in caretaker
  mode. **Aperture** has been dead since 2015 and photographers still mourn its ergonomics.
- **Affinity** was absorbed by Canva; its roadmap now serves a design-suite strategy, not
  photographers.
- **Capture One** (16.8.4) pivoted toward subscription and raised its studio pricing 344%,
  torching two decades of trust with exactly the professional users who cared most.
- **Adobe** (LrC 15.5) metered generative features behind credits (25/month on the base plan),
  shipped 15.0 with a masking regression users rolled back from, and had to pull 15.4 outright
  (Denoise posterization, AI-culling memory leaks freezing Macs). Its own 15.0 marketing headline,
  "everyday editing gets faster," is a concession that responsiveness is the product's top
  complaint.
- The open-source alternatives (darktable 5.6, RawTherapee 5.13) are engineering-rich and
  product-poor: four coexisting tone mappers, module names like "diffuse or sharpen," docs that
  warn "not suitable for beginners."

A working photographer who wants to own their tools, run them offline, and trust them mid-season
currently has no complete answer. That photographer is the owner of this project, who also happens
to be the developer. Lumen is the answer built to the owner's own standard, with no compromise for
a hypothetical mass market.

## 2. "Fast, accurate, easy," defined measurably

These three words are the product. Each one is a number or a test, not a mood.

### Fast

Perceived speed is governed by published perception thresholds, not by benchmarks of our choosing.
Card (1991) and Nielsen (1993) set the coarse limits: 0.1 s reads as instantaneous, 1 s breaks the
feeling of direct manipulation, 10 s loses attention entirely. Direct manipulation is an order of
magnitude stricter: Deber et al. (CHI 2015) measured perceivable drag latency at ~11 ms for direct
touch and ~55 ms for indirect input, and Ng et al. (UIST 2012) showed that at ~100 ms a dragged
object visibly trails the pointer. Lightroom's lag lives exactly in that perceivable band. Lumen's
budgets sit under the thresholds:

| Loop | Budget | Grounding |
|---|---|---|
| Slider, brush, pan, crop to visible change | ≤ 1 frame: 16.7 ms @ 60 Hz, 8.3 ms @ 120 Hz (approximation may refine ≤ 200 ms) | Deber 2015: ~11 ms drag perceivability; one frame is under the indirect threshold |
| Discrete actions: photo switch, panel open, rating write, filter collapse | ≤ 100 ms | Nielsen/Card 0.1 s instantaneous limit |
| Cull paging at fit zoom | < 50 ms, gated only by key-repeat rate | Photo Mechanic's architecture; flow dies above this |
| Grid scroll, 10k thumbnails | Zero dropped frames at 120 Hz | Hitch-rate is Apple's own scroll-quality KPI |
| AI denoise, 45 MP | ≤ 10 s, background, cancelable | Nielsen 10 s attention limit; beats LrC 15.4's 13–25 s ANE times |

These five loops (first browse, grid scroll, slider drag, photo switch, AI round-trip) are the
release gate, measured in CI on the owner's real hardware. A feature that busts its loop does not
ship (docs/12-spec-ux.md owns the budgets in detail; docs/16-roadmap.md owns the gate).

### Accurate

Accuracy is a set of engineering guarantees, each one a named fix for a named competitor failure:

- **One picture formation.** Scene-referred linear working space, exactly one hue-preserving
  AgX-class display transform (docs/14-pipeline.md). Per-channel S-curves cause the "Notorious
  Six" hue skews (bright reds to orange, blues to magenta); Lumen's transform is designed not to.
- **Right math in the right space** (Poynton's rule): physical operations in linear light,
  perceptual operations in perceptually uniform spaces, hue-preserving color tools in OKLab-class
  spaces. This is correctness, not taste, and it is enforced in the engine, never delegated to
  a user-facing color-space picker.
- **Halo-free by construction.** Clarity is local-Laplacian based; tonal-zone recovery runs on a
  guided-filter luminance mask. Lightroom halos at sky/land edges; Lumen must not (docs/06-spec-detail.md,
  docs/04-spec-tone.md).
- **Chroma-discipline.** Luminance moves in the color mixer do not desaturate (LR's artifact);
  saturation moves handle Helmholtz–Kohlrausch; gamut mapping is hue-preserving (docs/05-spec-color.md).
- **Raw truth.** The histogram can show actual raw channel data with per-channel clipped
  percentages. JPEG-pipeline histograms hide 0.3–2 EV of highlight headroom; FastRawViewer built a
  whole product on that lie, and Lumen folds the honest instrument in (docs/04-spec-tone.md, docs/10-spec-library.md).
- **Rendering never changes silently.** Golden-image tests per pipeline stage; recipes carry
  `pipelineVersion` from day 1; rendering-version migration is explicit and badged, never LR's
  silent process-version upgrade (docs/14-pipeline.md, docs/15-catalog.md).

### Easy

Ease is the two-registers principle, borrowed from the Lightroom bookshelf: "Kelby tells you how;
Evening tells you how and why," and both books are perennial sellers because both registers are
real. Lumen is one tool with two registers: an opinionated simple surface usable in minute one
(tone sliders, WB, crop, masks, looks) and full depth exactly one disclosure away. Per control,
the Pixelmator pattern applies: an auto/one-click entry point on top, manual controls beneath.
Never two parallel tools for one intent; never a hidden config flag governing layout. The
measurable form: a first-session user edits a photo without documentation, and an expert reaches
any deep control in at most one disclosure step. Every feature has keyboard access; every keyboard
action has a menu item. The Final Cut Pro X launch is the standing warning: simplification wins
only when the depth is demonstrably still there.

When the three are in tension, the standing priority order is: **image quality > interactivity >
feature count.**

## 3. The design laws

The canon below distills the 22 UX laws of the speed research (r12, operationalized in
docs/12-spec-ux.md) and the tool-design principles mined from the literature (docs/01-research-literature.md).
Every law cites the finding that grounds it. Specs cite laws by number.

### Laws of image truth

**Law 1. The camera gives data, not a picture; forming the picture is one deliberate act.**
Sobotka's doctrine and the VES *Cinematic Color* paper both hold that scene-referred data becomes
an image only through an explicit picture-formation transform. Lumen has exactly one display
transform. darktable's four coexisting tone mappers, with docs warning "never use together," are
the named anti-pattern.

**Law 2. Physical math in linear light, perceptual math in uniform spaces, and the user never
chooses.** Poynton's engineering rule: blur, resize, and exposure belong in linear; UI steps and
hue-preserving color moves belong in perceptual spaces. Getting this wrong produces wrong
pictures; exposing it produces the ProPhoto-vs-sRGB traps that fill forums. One correct managed
path, zero pickers.

**Law 3. The default rendering is the look, and the first render is the onboarding.** Capture
One's most-cited advantage is per-camera profiles that need less work; darktable quietly applies
+0.7 EV because honest-linear reads too dark; RapidRAW's over-aggressive auto (issue #568) shows
bad defaults are worse than none. Lumen ships a curated pictorial base per camera, documents it,
and keeps a flat/linear escape hatch.

**Law 4. Aim at preferred reproduction, not colorimetric truth.** Hunt's six objectives place
consumer photography under *preferred* reproduction: memory colors (skin, sky, foliage) are judged
against remembered ideals, and "a suntanned appearance is preferred even when not found in the
original." Defaults and memory-color tools target pleasing, which is a researched quantity, not a
vibe.

**Law 5. Skin is a protected class, judged relationally.** Margulis and Varis converge on channel
relationships, not absolutes (cyan ≈ 1/4–1/3 of magenta for Caucasian skin; ratios shift, logic
holds, across all ethnicities), and viewers detect 2–3% skin errors they would never see in
foliage. The vectorscope skin-tone line, with tolerance band, is the objective aid; global
saturation moves can hold skin inside it (docs/05-spec-color.md).

**Law 6. Trust instruments over adapted eyes.** Margulis's "color by the numbers" exists because
monitors and chromatic adaptation lie. Lumen keeps the histogram first-class and honest down to
the raw data (see §2, Accurate), with parade, waveform, and vectorscope one disclosure away in the
grading context, and numeric readouts that persist before/after.

**Law 7. The surround is part of the pipeline.** Fairchild's appearance phenomena (Bartleson–
Breneman, Hunt effect) mean a dark surround makes users over-cook contrast and saturation;
darktable's manual states it plainly and ships a mid-gray theme. Lumen chrome is zero-chroma
18–25% gray, the canvas surround is user-set, and one key toggles an ISO 12646 assessment mode.

*Amendment, 2026-08-29 (docs/28 Phase 2, owner-commissioned: "make the bars show temp, for
example lightroom has a blue to yellow tint on the temp slider").* **A control's track may carry
chroma if and only if that control's axis is itself a colour direction, and at no larger a scale
than the 4 pt groove.** Permitted, and nothing else: Temp (blue→amber), Tint (green→magenta), the
colour mixer's per-band hue, saturation and luminance tracks, and the luminance ramps under the
grading wheels. Explicitly **not** permitted: Exposure, Contrast, Highlights, Shadows, Whites,
Blacks, Texture, Clarity, Dehaze, Blending, Balance — every tonal control stays neutral. Adobe and
Capture One both arrived at this line independently, and the reason to hold it is this law's own:
a light-to-dark ramp beside a photograph being judged for exposure is precisely the contamination
Bartleson–Breneman warns about, whereas a blue→amber Temp track states the direction of an edit
that is *about* colour and cannot mislead a judgement it is already the subject of. Colour every
track and none of them reads; colour only the colour axes and every coloured track is
self-teaching. The surround, the panels, the wells, the fills, the type and every other pixel of
chrome remain zero-chroma, which is what the law was always for.

**Law 8. Contrast belongs where the curve is steep.** Margulis's steepest-part principle: assign
important image regions to the steep part of the transfer curve. It generalizes past LAB into
Lumen's zone tools and range-limited contrast affordances, and into color as separation around
pinned neutrals rather than global saturation.

**Law 9. Editing is performance, not correction.** Adams: "the negative is the score, the print
the performance." duChemin frames develop work as intention, mood, and drawing the eye. The
product consequence is that experimentation must be free: non-destructive always, unlimited
persistent history, cheap virtual copies and snapshots, instant A/B.

### Laws of speed

**Law 10. One frame or it doesn't feel attached.** Direct manipulation must show a visible change
within one display frame, refining within 200 ms. Grounded in Deber 2015 (~11 ms perceivable) and
Ng 2012 (the rubber-band effect); Adobe's serial "interactive-slider performance" patches show
what living above the threshold costs.

**Law 11. A tenth of a second for everything discrete, and pre-compute in the direction of
travel.** Photo switching, panel opens, rating writes, filter collapses: ≤ 100 ms. Photo
Mechanic's direction-aware prefetch (8 ahead, 2 behind at fit; ±1 at 1:1) is the model; paging is
gated only by key repeat.

**Law 12. Nothing synchronous on the input path, ever.** All five of Lightroom's distinct
slownesses trace to synchronous work where input lives: per-edit XMP flushes, synchronous mask
re-evaluation, blocking preview builds. Every fix Adobe shipped was a move-it-off-the-path fix.
Lumen starts there: metadata, sidecars, mask recompute, previews, AI, all async with badges.

**Law 13. Recompute only downstream, and cache the pipeline prefix.** Ansel's rewrite measured
5.4–40× faster parameter changes from downstream-only invalidation, with export reusing the
interactive cache. This is the single highest-leverage engine decision for perceived speed
(docs/14-pipeline.md).

**Law 14. Never decode what you don't show.** Photo Mechanic's founding refusal: browse on
embedded JPEGs, never the raw decode path; no import ceremony stands between a card and a contact
sheet. Lumen adopts all three refusals wholesale (docs/10-spec-library.md).

**Law 15. Progress has a ladder, and a modal dialog is a design failure.** Under 1 s: nothing.
1–10 s: inline spinner, result lands in place. Over 10 s: determinate progress, cancel, and a
background badge. Nielsen's 10 s limit plus the HIG's "passive status near the item." Lens Blur's
session-degrading waits are the anti-case.

**Law 16. The five loops are the release gate, and stability is UX.** First browse, grid scroll,
slider drag, photo switch, AI round-trip: numeric budgets in CI, on the owner's Mac. Lightroom
15.4 was pulled mid-season and taught its users never to update during work; Lumen's owner updates
mid-wedding-season, so a release that could break that trust does not exist.

### Laws of control

**Law 17. Every action has a key; every key action has a menu item.** Apple's HIG toolbar rule,
generalized. The culling grammar matches Lightroom keystroke-for-keystroke (P/X/U, 1–5, 6–9,
G/E/C/N) because that muscle memory is twenty years deep; auto-advance is default-on and visible,
not a Caps-Lock easter egg.

**Law 18. The pointer is optional.** Capture One's Speed Edit (hold a key, drag or scroll
anywhere) is the best-received ergonomic idea of the decade in raw editing: it deletes the Fitts
cost of aiming, keeps eyes on the image, and batches across the selection. Lumen ships it with
curated defaults and an on-image ghost readout (docs/12-spec-ux.md).

**Law 19. One slider contract everywhere.** Click-anywhere row, scrubby number, typed entry with
arithmetic, arrow nudges (Shift ×10, Alt fine), double-click reset, visible per-slider auto, soft
limits with typed override, Alt+scroll only. Synthesized from darktable's five-way slider and
Lightroom's load-bearing hidden conventions; LR's 2025 double-click-reset regression drew instant
complaint threads, proof these are contracts, not niceties.

**Law 20. Direct-on-image wherever it's cheap, never as the only path.** The targeted-adjustment
drag, draggable histogram zones, scroll-to-dodge on tone zones, amount-scrub on mask pins. The
U-Point history teaches the balance: an in-context HUD of at most 3 controls plus a full panel;
DxO's move to panel-only was approved for scale and mourned for directness.

**Law 21. Two registers, one tool; disclosure, never modes.** The Kelby/Evening split as
architecture (§2 Easy). Defaults set perceived complexity, not options: darktable has the deepest
disclosure system in the field and still reads as intimidating because its default surface is the
full module set. Lumen's default surface is minute-one usable and its depth is always one visible
step away.

**Law 22. Decisive macro-moves beat forty timid nudges.** Margulis's Picture Postcard Workflow
averages 3 minutes per image with three ordered passes; that pace is a design KPI for the
high-volume event register. One-click compound operations, batch apply, and per-control autos
carry the first pass; sliders refine, they don't excavate.

### Laws of trust

**Law 23. AI proposes with evidence; the user disposes.** The consistent verdict across Topaz
("Autopilot decided my sky was a subject"), LR Auto (visible slider moves, right model; hidden
Adaptive Profiles, wrong one), and every assisted-culling tool: suggest-then-adjust wins, silent
auto-apply loses. Every AI result lands as inspectable, editable state. Expanded in §5.

**Law 24. History is persistent, coalesced, and legible; errors are named; the platform is
honored.** History survives restarts (LR and darktable both do this; users treat it as insurance),
slider drags coalesce into one undo step (per Apple's HIG), snapshots stand in for branches nobody
asked for. Waits show causes and ETAs, never "Something went wrong" (LR's most despised string).
And Lumen is a real Mac app: full menu bar, system full screen, customizable toolbar, instant
gestures, a second pinnable viewer window with sane keyboard focus where LR's steals it.

## 4. Develop and Look: the split that is the product

Lumen's edit model is cut in two, and the cut is philosophical before it is architectural.

**Develop** makes the file true: white balance, exposure normalization, lens corrections, denoise,
capture sharpening. It is per-image by nature, because every frame's light is different.
**Look** makes the set yours: color grading, film lab, B&W treatment, creative contrast. It is
portable by nature, because intent spans frames.

This is cinema doctrine imported whole. Hullfish's colorists do primaries strictly before
secondaries; Van Hurkman devotes a chapter to shot matching and scene balancing, which only works
because normalization and look are separable; Adams's score/performance metaphor lands here too:
Develop reads the score faithfully, Look performs it. Lightroom collapses the two into one
undifferentiated slider soup, which is why applying one aesthetic across an 800-frame event is a
copy-paste ritual with wrong exposure baked in. In Lumen, the Look layer applies set-wide in one
gesture while per-frame Develop absorbs the variance underneath it. One look across 800 frames is
a feature, not a workflow.

The split is architectural from day 1: the recipe format carries the two layers distinctly
(docs/15-catalog.md), the pipeline orders them (docs/14-pipeline.md), and the UI presents them as
the two top-level editing contexts (docs/12-spec-ux.md). Presets respect the boundary, so a film
look never smuggles in someone's white balance.

## 5. The AI doctrine

Lumen uses machine learning aggressively and under three rules that never bend:

1. **Local only.** Every model runs on-device via Core ML, license-verified (docs/17-appendix.md
   holds the ledger). No cloud round-trips, no accounts, no credits, no upload anxiety. Adobe's
   25-credits-per-month metering turned a tool into a taxi meter; darktable 5.6's strictly-local
   ONNX policy shows the alternative is practical.
2. **Scene integrity.** AI fixes defects, selects regions, and proposes settings. It never invents
   content. darktable 5.6 states the policy in five words, "fix defects, never change scene
   content," and Lumen adopts it with one pragmatic exception: object-removal inpainting
   (docs/09-spec-geometry.md), because removing a trash can is finishing craft photographers have
   practiced since the darkroom, and the fill reconstructs what plausibly stood behind an object
   rather than imagining what was never there. Nothing beyond that: no generative expand, no sky
   replacement, no invented pixels presented as photographs.
3. **Evidence, not verdicts.** AI output arrives as proposals with visible reasons: per-face crops
   with eyes-open and focus badges at cull time, auto-tone as visible slider positions the user
   then tunes, masks as editable objects. Adjustable strictness, flags never deletions, accept and
   reject on single keys, and everything lands in history as inspectable state. The anti-patterns
   are named: Topaz Autopilot's unpredictable auto-apply, LR Adaptive Profiles' corrections hidden
   at slider-zero, and LR 15.0's synchronous mask recompute that made batch editing impractical.

One master switch in preferences disables every model. It ships on — everything it governs is
local and license-verified, so confidence is the default — and off is genuinely off: no weights
load, no runtime starts, no model scans run. The app must remain excellent either way, because
trust in the tool cannot depend on trusting the models.

## 6. What Lumen refuses to build

Refusals are load-bearing. Each one buys speed, trust, or focus, and each is grounded.

- **No cloud, no accounts, no sync, no telemetry.** The product's core promise is ownership and
  privacy; one network feature poisons it. Local-only is also a speed feature: no editor with a
  cloud dependency has ever won a latency argument.
- **No subscription, no credits, ever.** The market vacuum in §1 was created by exactly these two
  mechanisms. Lumen is not sold at all; it is the owner's tool. The discipline still matters
  because it forbids any architecture that would need a server to justify itself.
- **No generative content.** Beyond removal inpainting (§5), nothing invents pixels. A photo
  editor that fabricates content is a different product with a different relationship to truth.
- **No plugin API.** Plugins freeze internal interfaces before they are right, and the pipeline's
  performance discipline (Laws 12–13) cannot be enforced across third-party code. One user does
  not need an ecosystem.
- **No video.** Video multiplies every subsystem (I/O, caching, timeline UI, audio) and is why
  hybrid tools feel unfinished at both jobs. Resolve exists.
- **No Windows, no Linux, no iPad.** The plan's feasibility rests on Apple's platform doing the
  heaviest lifting (CIRAWFilter, Vision, Core ML, Metal, EDR). Portability would forfeit the
  advantage that makes a one-person build possible (docs/13-architecture.md).
- **No tethering.** A studio-workflow feature demanding per-camera SDK maintenance; the owner does
  not tether, and C1 can keep that market.
- **No publish services, book, slideshow, print, or web modules.** Export to disk covers every
  real delivery path in 2026. These are LR's least-loved, least-maintained surface area.
- **No face-recognition database, no map module.** Photos.app already does both well for the
  one-user case; culling-time face evidence (badges, crops) is a different feature and is in scope.
- **No user-facing color-management picker and no second tone mapper.** Laws 1 and 2. One correct
  managed path; darktable's four-transform museum is what refusing this refusal looks like.
- **No modal keyboard grammar.** Flat single keys with modifiers, like every creative tool that
  succeeded with keyboard-first design. Vim's power is real and its first hour is disqualifying.
- **No Lightroom rendering emulation.** Lumen migrates files and muscle memory, not recipes.
  Pixel-matching LR's engine would chain the pipeline to a competitor's history; the grammar is
  compatible, the look is ours.

## 7. Who this is for, and the accepted costs

Lumen is built for its owner, a photographer-developer who shoots all four of its target genres,
and each genre stresses a different pillar of the plan:

| Genre | What it demands | Where the plan answers |
|---|---|---|
| Portraits | Skin as a protected class, memory-color tools, hair-grade masks | docs/05-spec-color.md, docs/08-spec-masking.md |
| Landscape / travel | Halo-free detail, honest raw highlights, geometry and heal, print-grade output | docs/06-spec-detail.md, docs/09-spec-geometry.md, docs/11-spec-output.md |
| Events / high volume | Photo Mechanic-class culling, Develop/Look batch grammar, 3-minute pace | docs/10-spec-library.md, §4, Law 22 |
| Low light / night | Scene-referred highlight handling, two-tier denoise, hot-pixel control | docs/04-spec-tone.md, docs/07-spec-denoise.md |

The one-user, one-platform scope has real costs, accepted with eyes open:

- **One user's taste is the only validation.** Blind spots are inevitable. Mitigations: the
  keystroke-for-keystroke LR grammar keeps decades of community muscle memory portable into the
  app, and the competitive teardowns (docs/02-research-lightroom.md, docs/03-research-competitors.md)
  stand in for the user research a company would run.
- **Apple dependency.** CIRAWFilter's rendering can change under us; the answer is pinning
  `decoderVersion`, golden-image tests, and the `RawSource` escape hatch to our own decode path
  (docs/14-pipeline.md). Betting on the platform is still correct: it is the bet that makes the
  project one-person-sized.
- **Solo capacity.** The roadmap (docs/16-roadmap.md) is sized honestly, phase exits are tests on
  real photos, and ship-to-self weekly from Phase 1 keeps annoyance, not ambition, driving the
  backlog.
- **No revenue pressure means no external deadline.** The discipline substitute is the release
  gate (Law 16) and the standing rule that the owner uses the current build for real work every
  week.

The finish line is stated once and measured forever: a tool the owner opens after a 3,000-frame
wedding weekend without dread, that never shows a beachball, never phones home, never changes a
rendering silently, and produces better color than the subscription it replaced.
